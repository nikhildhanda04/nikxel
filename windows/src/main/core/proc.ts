import { spawn, SpawnOptions, ChildProcess } from "child_process";
import * as fs from "fs";
import * as path from "path";
import { HOME, isWin } from "./paths";

/// Process helpers. Everything Nikxel shells out to (git, whisper, ffmpeg, the
/// coding agents) goes through here, because Windows has three traps the Mac
/// code never had to think about:
///
///  1. npm-installed CLIs (claude, codex, opencode) are `.cmd` shims, and Node
///     refuses to spawn .cmd/.bat without a shell (CVE-2024-27980). Going
///     through cmd.exe caps the command line at ~8 KB and mangles quotes, so
///     `resolveLaunch` reads the shim and runs its target script with node
///     directly when it can.
///  2. A GUI app spawning a console program flashes a console window unless
///     windowsHide is set. It always is here.
///  3. A packaged app doesn't inherit the PATH a terminal has (npm's global
///     bin, scoop shims, ~/.local/bin), so `which` also looks there.

export interface RunOptions {
  cwd?: string;
  env?: NodeJS.ProcessEnv;
  /// Written to stdin, then stdin is closed. Prefer this over long arguments.
  input?: string;
  /// Kill after this many ms; result.timedOut is set.
  timeoutMs?: number;
  /// Called with each stdout chunk as it arrives.
  onStdout?: (chunk: string) => void;
  onStderr?: (chunk: string) => void;
}

export interface RunResult {
  code: number | null;
  stdout: string;
  stderr: string;
  timedOut: boolean;
  /// Set when the process couldn't start at all (ENOENT, EACCES).
  error?: Error;
}

/// Extra directories a terminal would have on PATH but a launched app may not.
export function extraPathDirs(): string[] {
  const dirs: string[] = [];
  if (isWin) {
    const appData = process.env.APPDATA ?? path.join(HOME, "AppData", "Roaming");
    const local = process.env.LOCALAPPDATA ?? path.join(HOME, "AppData", "Local");
    dirs.push(
      path.join(appData, "npm"),
      path.join(HOME, ".local", "bin"),
      path.join(HOME, "scoop", "shims"),
      path.join(local, "Microsoft", "WinGet", "Links"),
      path.join(local, "Programs", "Git", "cmd"),
      path.join(HOME, ".opencode", "bin"),
      path.join(HOME, ".nikxel", "bin"),
      "C:\\Program Files\\Git\\cmd",
      "C:\\Program Files\\nodejs",
      "C:\\ProgramData\\chocolatey\\bin",
    );
  } else {
    dirs.push("/opt/homebrew/bin", "/usr/local/bin", path.join(HOME, ".local", "bin"), path.join(HOME, ".nikxel", "bin"));
  }
  return dirs;
}

/// process.env with the extra dirs appended to PATH.
export function augmentedEnv(extra?: NodeJS.ProcessEnv): NodeJS.ProcessEnv {
  const env: NodeJS.ProcessEnv = { ...process.env, ...extra };
  const key = Object.keys(env).find(k => k.toUpperCase() === "PATH") ?? "PATH";
  const parts = (env[key] ?? "").split(path.delimiter).filter(Boolean);
  for (const d of extraPathDirs()) if (!parts.includes(d)) parts.push(d);
  env[key] = parts.join(path.delimiter);
  return env;
}

function isFile(p: string): boolean {
  try { return fs.statSync(p).isFile(); } catch { return false; }
}

/// Full path of an executable by name, searching PATH plus extraPathDirs().
/// On Windows tries each PATHEXT extension (.exe, .cmd, ...). Also accepts an
/// absolute path, returned as-is if it exists.
const found = new Map<string, string>();

/// Hits are cached (a tool that's gone is looked up again); misses aren't,
/// since setup installs tools while Nikxel runs. Every git call came through
/// here, statting each PATH directory times each PATHEXT extension.
export function which(name: string, extraCandidates: string[] = []): string | null {
  const key = name + "\0" + extraCandidates.join("\0");
  const hit = found.get(key);
  if (hit && isFile(hit)) return hit;
  const p = lookup(name, extraCandidates);
  if (p) found.set(key, p); else found.delete(key);
  return p;
}

function lookup(name: string, extraCandidates: string[]): string | null {
  for (const c of extraCandidates) if (isFile(c)) return c;
  if (path.isAbsolute(name)) return isFile(name) ? name : null;
  const env = augmentedEnv();
  const pathKey = Object.keys(env).find(k => k.toUpperCase() === "PATH") ?? "PATH";
  const dirs = (env[pathKey] ?? "").split(path.delimiter).filter(Boolean);
  const exts = isWin
    ? (path.extname(name) ? [""] : (process.env.PATHEXT ?? ".COM;.EXE;.BAT;.CMD").split(";").map(e => e.toLowerCase()))
    : [""];
  for (const d of dirs) {
    for (const e of exts) {
      const p = path.join(d.replace(/^"|"$/g, ""), name + e);
      if (isFile(p)) return p;
    }
  }
  return null;
}

/// Quote one argument for cmd.exe + the MSVC argv parser.
function cmdQuote(arg: string): string {
  if (arg === "") return '""';
  let a = arg;
  if (/[\s"]/.test(a)) {
    a = a.replace(/(\\*)"/g, '$1$1\\"').replace(/(\\*)$/, "$1$1");
    a = `"${a}"`;
  }
  return a.replace(/[()%!^"<>&|]/g, "^$&");
}

/// How to actually launch `bin args`. For an npm .cmd shim, reads the shim
/// and runs the node script it points at, so there's no cmd.exe in between.
export function resolveLaunch(bin: string, args: string[]): { file: string; args: string[]; verbatim: boolean } {
  if (!isWin || !/\.(cmd|bat)$/i.test(bin)) return { file: bin, args, verbatim: false };
  const shim = fs.existsSync(bin) ? fs.readFileSync(bin, "utf8") : "";
  // npm shims: "%_prog%"  "%dp0%\node_modules\pkg\cli.js" %*
  //        or: "%dp0%\node_modules\pkg\bin\tool.exe"   %*
  const target = shim.match(/"%~?dp0%?\\([^"]+\.(?:js|cjs|mjs|exe))"/i);
  if (target) {
    const script = path.join(path.dirname(bin), target[1]);
    if (fs.existsSync(script)) {
      if (/\.exe$/i.test(script)) return { file: script, args, verbatim: false };
      const localNode = path.join(path.dirname(bin), "node.exe");
      const node = isFile(localNode) ? localNode : which("node");
      if (node) return { file: node, args: [script, ...args], verbatim: false };
    }
  }
  const line = [cmdQuote(bin), ...args.map(cmdQuote)].join(" ");
  return { file: process.env.ComSpec ?? "cmd.exe", args: ["/d", "/s", "/c", `"${line}"`], verbatim: true };
}

/// Spawn with Windows-safe defaults. The caller owns the child.
export function spawnProcess(bin: string, args: string[], opts: SpawnOptions = {}): ChildProcess {
  const l = resolveLaunch(bin, args);
  return spawn(l.file, l.args, {
    windowsHide: true,
    windowsVerbatimArguments: l.verbatim,
    ...opts,
    env: augmentedEnv(opts.env as NodeJS.ProcessEnv | undefined),
  });
}

/// Run to completion and collect output. Never rejects.
export function run(bin: string, args: string[], opts: RunOptions = {}): Promise<RunResult> {
  return new Promise(resolve => {
    let stdout = "", stderr = "", timedOut = false, settled = false;
    let child: ChildProcess;
    try {
      child = spawnProcess(bin, args, { cwd: opts.cwd, env: opts.env, stdio: ["pipe", "pipe", "pipe"] });
    } catch (e) {
      resolve({ code: null, stdout: "", stderr: String(e), timedOut: false, error: e as Error });
      return;
    }
    const finish = (r: RunResult) => { if (!settled) { settled = true; if (timer) clearTimeout(timer); resolve(r); } };
    const timer = opts.timeoutMs ? setTimeout(() => { timedOut = true; killTree(child); }, opts.timeoutMs) : undefined;
    child.stdout?.setEncoding("utf8");
    child.stderr?.setEncoding("utf8");
    child.stdout?.on("data", (d: string) => { stdout += d; opts.onStdout?.(d); });
    child.stderr?.on("data", (d: string) => { stderr += d; opts.onStderr?.(d); });
    child.on("error", err => finish({ code: null, stdout, stderr: stderr || String(err), timedOut, error: err }));
    child.on("close", code => finish({ code, stdout, stderr, timedOut }));
    child.stdin?.on("error", () => { /* child exited before reading stdin */ });
    if (opts.input !== undefined) child.stdin?.end(opts.input);
    else child.stdin?.end();
  });
}

/// Kill a process and its children. On Windows child.kill() leaves a node
/// script's own children (the agent's subprocesses) running.
export function killTree(child: ChildProcess): void {
  if (child.pid === undefined || child.exitCode !== null) return;
  if (isWin) {
    spawn("taskkill", ["/pid", String(child.pid), "/T", "/F"], { windowsHide: true, stdio: "ignore" }).on("error", () => child.kill());
  } else {
    child.kill("SIGTERM");
  }
}

/// Run a PowerShell script and return stdout. The script goes in as
/// -EncodedCommand, so there is no quoting to get wrong.
export function powershell(script: string, opts: RunOptions = {}): Promise<RunResult> {
  const encoded = Buffer.from(script, "utf16le").toString("base64");
  return run("powershell.exe", ["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-EncodedCommand", encoded], opts);
}
