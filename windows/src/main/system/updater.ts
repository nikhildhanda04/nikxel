import * as fs from "fs";
import * as os from "os";
import * as path from "path";
import { spawn } from "child_process";
import { randomUUID } from "crypto";
import { appSourceRoot, nikxelPath, readText } from "../core/paths";
import { run, which, augmentedEnv } from "../core/proc";
import { diag } from "../core/diag";

/// Self-update: fetch `origin/main`, and on request pull, rebuild and relaunch.
///
/// Nikxel for Windows runs from a clone (`windows/` inside the repo), so
/// "update" is `git pull` plus `npm ci && npm run build` -- exactly what the
/// README tells you to run by hand. The only real problem is that **the app
/// cannot do this to itself while running**: the build rewrites the `dist/`
/// the process is executing from, and `npm ci` replaces `node_modules`
/// (electron.exe included), which Windows refuses to delete while it runs. So
/// the work is handed to a detached PowerShell script that outlives the app
/// -- it waits for Nikxel to quit, does the update, and launches the new build.
///
/// If the pull or the build fails, that script puts the previous commit back
/// and rebuilds it. A failed update must never leave somebody with no app.

export interface UpdateStatus {
  repo: string;
  isUpToDate: boolean;
  /// The commit this build came from.
  currentCommit: string;
  /// How many commits `origin/main` is ahead of the running build.
  behind: number;
  branch: string;
  /// Uncommitted changes to tracked files, which would stop a pull.
  dirty: boolean;
  /// A fast-forward pull only works from main with a clean tree.
  canAutoUpdate: boolean;
  /// Their subject lines, newest first.
  subjects: string[];
}

export class UpdateError extends Error {
  /// Set when the clone exists but Windows won't let Nikxel list it
  /// (Controlled folder access). The folder's path.
  readonly noFolderAccess?: string;
  constructor(message: string, noFolderAccess?: string) {
    super(message);
    this.name = "UpdateError";
    if (noFolderAccess) this.noFolderAccess = noFolderAccess;
  }
}

const NOT_A_CLONE = `Nikxel isn't running from a git clone, so it can't update itself.

Clone the repo and run it from there:
git clone https://github.com/nikhildhanda04/nikxel.git
cd nikxel\\windows
npm ci
npm start`;

const NO_GIT = `Git isn't installed (or Nikxel can't find it), so it can't check for updates.

Install Git for Windows from https://git-scm.com/download/win, then check again.`;

/// Builds a status, deriving the two flags the same way the Mac's computed
/// properties did. Exported for the checks.
export function makeStatus(s: Omit<UpdateStatus, "isUpToDate" | "canAutoUpdate">): UpdateStatus {
  return { ...s, isUpToDate: s.behind === 0, canAutoUpdate: !s.dirty && s.branch === "main" };
}

/// Shorten a commit subject for a card line, breaking at a word boundary.
/// A hard `prefix(n)` cut one mid-word ("lacks the signing cer"), which
/// reads as a rendering fault rather than a deliberate truncation.
function shortSubject(subject: string, limit = 64): string {
  const s = subject.trim();
  const chars = Array.from(s);
  if (chars.length <= limit) return s;
  const cut = chars.slice(0, limit).join("");
  // Back up to the last space so a word is never sliced. If there isn't
  // one (a single long token), cut where we are.
  const space = cut.lastIndexOf(" ");
  if (space >= 0) {
    const trimmed = cut.slice(0, space).trim();
    if (trimmed) return trimmed + "…";
  }
  return cut + "…";
}

/// The windows/ app folder this build runs from, or null for an installed build.
function appDir(): string | null {
  return appSourceRoot();
}

/// The clone this app was built in: the nearest folder above the app folder
/// that holds `.git` (a directory, or a file for a worktree). An installed
/// build has no source folder at all and must not be offered an update.
function findRepoRoot(): string | null {
  const start = appDir();
  if (!start) return null;
  let dir = path.resolve(start);
  for (;;) {
    if (fs.existsSync(path.join(dir, ".git"))) return dir;
    const up = path.dirname(dir);
    if (up === dir) return null;
    dir = up;
  }
}

async function git(repo: string, args: string[], timeoutMs = 60_000): Promise<{ ok: boolean; output: string }> {
  const bin = which("git");
  if (!bin) return { ok: false, output: NO_GIT };
  const r = await run(bin, ["-C", repo, ...args], {
    timeoutMs,
    // A clone made over SSH, or a credential helper wanting input, would
    // otherwise hang the fetch forever behind a prompt nobody can see. Git
    // Credential Manager would pop a sign-in window instead; same rule.
    env: { GIT_TERMINAL_PROMPT: "0", GCM_INTERACTIVE: "never" },
  });
  const output = (r.stdout + (r.stderr ? (r.stdout ? "\n" : "") + r.stderr : "")).trim();
  if (r.timedOut) return { ok: false, output: output || "git timed out" };
  return { ok: r.code === 0, output: r.code === 0 ? r.stdout.trim() : output };
}

/// The commit `npm run build` last produced, stamped by the update script
/// into dist/commit. Builds made by hand have no stamp and fall back to HEAD.
function builtCommit(): string | null {
  const dir = appDir();
  if (!dir) return null;
  const stamp = path.join(dir, "dist", "commit");
  // A build made by hand after an update leaves an old stamp behind. tsc
  // rewrites this very file on every build, so a stamp older than it
  // describes some earlier build.
  try {
    if (fs.statSync(stamp).mtimeMs + 60_000 < fs.statSync(__filename).mtimeMs) return null;
  } catch { return null; }
  return readText(stamp)?.trim() || null;
}

async function check(): Promise<UpdateStatus> {
  const repo = findRepoRoot();
  if (!repo) {
    const dir = appDir();
    if (dir) {
      let blocked = false;
      try { fs.readdirSync(dir); } catch { blocked = true; }
      if (blocked) {
        throw new UpdateError(
          `Windows is keeping Nikxel out of its own folder (${path.basename(dir)}), so it can't see the update.\n\n` +
          "If Controlled folder access is on (Windows Security → Ransomware protection), allow Nikxel there, then check again.",
          dir);
      }
    }
    throw new UpdateError(NOT_A_CLONE);
  }
  if (!which("git")) throw new UpdateError(NO_GIT);

  const fetch = await git(repo, ["fetch", "origin", "main"], 90_000);
  if (!fetch.ok) throw new UpdateError(`Couldn't reach GitHub.\n\n${fetch.output}`);

  // Compare the build, not HEAD: a build that failed half-way leaves HEAD
  // somewhere the running code isn't. Builds from before the stamp fall
  // back to HEAD.
  const built = builtCommit();
  const base = built && (await git(repo, ["cat-file", "-e", `${built}^{commit}`])).ok ? built : "HEAD";
  const count = await git(repo, ["rev-list", "--count", `${base}..origin/main`]);
  const behind = parseInt(count.output, 10);
  if (!count.ok || !Number.isFinite(behind)) {
    throw new UpdateError(`Couldn't compare against origin/main.\n\n${count.output}`);
  }

  const subjects = behind === 0 ? [] :
    (await git(repo, ["log", "--pretty=format:%s", `${base}..origin/main`])).output
      .split(/\r?\n/).filter(s => s !== "");

  const [current, branch, status] = await Promise.all([
    git(repo, ["rev-parse", "--short", base]),
    git(repo, ["rev-parse", "--abbrev-ref", "HEAD"]),
    // --porcelain lists untracked files too; -uno drops them, since build
    // output and anything else ignored can't block a pull.
    git(repo, ["status", "--porcelain", "-uno"]),
  ]);
  return makeStatus({
    repo,
    behind,
    subjects,
    currentCommit: current.output,
    branch: branch.output,
    dirty: status.output !== "",
  });
}

/// A PowerShell single-quoted literal.
function psq(s: string): string {
  return `'${s.replace(/'/g, "''")}'`;
}

/// One argument for a Windows command line (Start-Process -ArgumentList
/// joins its items with spaces and quotes nothing).
function winArg(a: string): string {
  if (a !== "" && !/[\s"]/.test(a)) return a;
  return `"${a.replace(/(\\*)"/g, '$1$1\\"').replace(/(\\*)$/, "$1$1")}"`;
}

/// How to start Nikxel again once the update is done: the same executable
/// with the same arguments, but with the app folder made absolute (a dev
/// launch is `electron .`, and the script doesn't run from that cwd).
function relaunchCommand(app: string): { exe: string; args: string } {
  const exe = process.execPath;
  const defaultApp = (process as NodeJS.Process & { defaultApp?: boolean }).defaultApp;
  if (defaultApp) {
    // electron.exe <app folder> [flags]: keep the flags, pin the folder.
    const rest = process.argv.slice(2).filter(a => a.startsWith("-"));
    return { exe, args: [app, ...rest].map(winArg).join(" ") };
  }
  const args = process.argv.slice(1).map(a => {
    if (a.startsWith("-")) return a;
    const abs = path.resolve(process.cwd(), a);
    return fs.existsSync(abs) ? abs : a;
  });
  return { exe, args: args.map(winArg).join(" ") };
}

/// Hands the update to a detached script; the caller quits. Returns false
/// if the script couldn't be started, in which case nothing has happened yet.
function updateAndRestart(repo: string): boolean {
  const app = appDir();
  if (!app) return false;
  const gitBin = which("git");
  const npmBin = which("npm");
  if (!gitBin || !npmBin) {
    diag("update", `can't update: git=${gitBin} npm=${npmBin}`);
    return false;
  }
  const relaunch = relaunchCommand(app);
  const appRel = path.relative(repo, app).replace(/\\/g, "/") || ".";

  const script = `# Written by Nikxel's "Check for Updates". Runs after Nikxel quits, because
# the build rewrites the dist/ the app runs from and npm ci replaces the
# electron.exe it is executing.
$ErrorActionPreference = 'Continue'
$log = ${psq(Updater.logPath)}
$repo = ${psq(repo)}
$app = ${psq(app)}
$git = ${psq(gitBin)}
$npm = ${psq(npmBin)}
$waitPid = ${process.pid}
$launchExe = ${psq(relaunch.exe)}
$launchArgs = ${psq(relaunch.args)}

function Log([string]$m) { Add-Content -LiteralPath $log -Value $m -Encoding UTF8 }
# Runs a native command with its output appended to the log; returns the exit code.
function Run([string]$exe, [string[]]$argv, [string]$cwd) {
  Push-Location -LiteralPath $cwd
  try { & $exe @argv 2>&1 | ForEach-Object { Log ([string]$_) } | Out-Null; $code = $LASTEXITCODE }
  catch { Log ("    " + $_); $code = 1 }
  finally { Pop-Location }
  if ($null -eq $code) { $code = 0 }
  return [int]$code
}
function Relaunch {
  if ($launchArgs) { Start-Process -FilePath $launchExe -ArgumentList $launchArgs -WorkingDirectory $app }
  else { Start-Process -FilePath $launchExe -WorkingDirectory $app }
}
function Stamp {
  $head = (& $git -C $repo rev-parse HEAD 2>$null)
  if ($head) { Set-Content -LiteralPath (Join-Path $app 'dist\\commit') -Value $head -Encoding ASCII }
}
function Build {
  # npm ci only when the dependencies changed (or are missing): it deletes
  # node_modules and downloads Electron again, minutes for nothing otherwise.
  if ($script:depsChanged -or -not (Test-Path -LiteralPath (Join-Path $app 'node_modules\\electron\\dist\\electron.exe'))) {
    Log "--- npm ci"
    if ((Run $npm @('ci') $app) -ne 0) { return $false }
  }
  Log "--- npm run build"
  if ((Run $npm @('run', 'build') $app) -ne 0) { return $false }
  return $true
}

Log ""
Log ("=== update started " + (Get-Date))
if (-not (Test-Path -LiteralPath $repo)) { Log "repo gone: $repo"; exit 1 }

# Wait for the old process to go away (up to 30s), then for Electron's own
# helper processes from this folder (GPU, renderers), which keep
# electron.exe and its DLLs locked.
for ($i = 0; $i -lt 60; $i++) {
  if (-not (Get-Process -Id $waitPid -ErrorAction SilentlyContinue)) { break }
  Start-Sleep -Milliseconds 500
}
for ($i = 0; $i -lt 30; $i++) {
  $left = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.Path -and $_.Path.StartsWith($app, [StringComparison]::OrdinalIgnoreCase) })
  if ($left.Count -eq 0) { break }
  Start-Sleep -Milliseconds 500
}

$prev = (& $git -C $repo rev-parse HEAD 2>$null)
Log ("--- before: " + (& $git -C $repo log --oneline -1 2>$null))
if ((Run $git @('pull', '--ff-only') $repo) -ne 0) {
  # Nothing changed on disk; the old build is still whole.
  Log "--- pull failed; relaunching the current build"
  Relaunch
  exit 1
}
Log ("--- after:  " + (& $git -C $repo log --oneline -1 2>$null))
& $git -C $repo diff --quiet $prev HEAD -- ${psq(appRel + "/package.json")} ${psq(appRel + "/package-lock.json")} 2>$null
$script:depsChanged = ($LASTEXITCODE -ne 0)

if (-not (Build)) {
  Log "--- update failed; restoring the previous build"
  # --keep rather than --hard: it refuses instead of discarding anything
  # local, and the tree was clean (canAutoUpdate) before the pull.
  if ((Run $git @('reset', '--keep', $prev) $repo) -ne 0) { Log "--- couldn't reset to $prev" }
  $script:depsChanged = $true
  if (Build) { Stamp; Log ("--- restored: " + (& $git -C $repo log --oneline -1 2>$null)) }
  else { Log "--- restore build failed too; run npm ci and npm run build in $app by hand" }
  Relaunch
  exit 1
}

Stamp
Log "=== update complete"
Relaunch
`;

  const file = path.join(os.tmpdir(), `nikxel-update-${randomUUID()}.ps1`);
  try {
    // BOM: Windows PowerShell 5.1 reads a BOM-less script as the ANSI code
    // page, which mangles any non-ASCII character in the user's paths.
    fs.writeFileSync(file, "﻿" + script, "utf8");
  } catch (e) {
    diag("update", `couldn't write update script: ${e}`);
    return false;
  }
  try {
    // Detached with no handles of ours, so it survives this process quitting.
    const child = spawn("powershell.exe",
      ["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-WindowStyle", "Hidden", "-File", file],
      { detached: true, stdio: "ignore", windowsHide: true, env: augmentedEnv(), cwd: os.tmpdir() });
    // Before anything can return: an 'error' with no listener would throw
    // and take the main process down with it.
    child.on("error", e => diag("update", `update script failed to start: ${e}`));
    if (child.pid === undefined) return false;
    child.unref();
    diag("update", `update script started (pid ${child.pid}): ${file}`);
    return true;
  } catch (e) {
    diag("update", `couldn't start update script: ${e}`);
    return false;
  }
}

export const Updater = {
  logPath: nikxelPath("update.log"),
  get repoRoot(): string | null { return findRepoRoot(); },
  check,
  updateAndRestart,
  shortSubject,
};
