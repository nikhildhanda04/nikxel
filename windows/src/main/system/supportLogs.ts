import * as fs from "fs";
import * as os from "os";
import * as path from "path";
import { app, systemPreferences, webContents } from "electron";
import { NIKXEL_DIR } from "../core/paths";
import { run, which, powershell } from "../core/proc";
import { Updater } from "./updater";

/// "Copy Logs" in the menu: one plain-text report for a user to paste into a
/// chat when something breaks, instead of being walked through folders.
/// Tails only -- the logs hold chat and meeting text, so it sends the least
/// that still shows what went wrong.
async function report(): Promise<string> {
  const nx = NIKXEL_DIR;
  let out = `Nikxel logs — ${new Date().toString()}\n`;
  out += `Windows ${os.release()}${typeof os.version === "function" ? ` (${os.version()})` : ""} ${os.arch()}\n`;
  out += `App: ${safe(() => app.getAppPath())} v${safe(() => app.getVersion())} (Electron ${process.versions.electron ?? "?"})\n`;
  const repo = Updater.repoRoot;
  const gitBin = which("git");
  if (repo && gitBin) {
    const r = await run(gitBin, ["-C", repo, "log", "--oneline", "-1"], { timeoutMs: 10_000 });
    out += `Commit: ${(r.stdout || r.stderr).trim()}\n`;
  }
  // Windows has no Accessibility or Screen Recording grant; the microphone
  // privacy switch is the one that can be off.
  out += `Permissions: mic=${safe(() => systemPreferences.getMediaAccessStatus("microphone"))}\n`;
  out += "Memory: " + await memory() + "\n";

  out += section("chatbot.log", await tail(path.join(nx, "chatbot.log"), 60));
  out += section("debug.log", await tail(path.join(nx, "debug.log"), 40));
  out += section("update.log", await tail(path.join(nx, "update.log"), 30));

  // Newest summary run: its stderr/stdout say why notes failed.
  const ws = path.join(nx, "momworkspace");
  try {
    const runs = (await fs.promises.readdir(ws)).filter(n => /^\d/.test(n)).sort();
    const last = runs[runs.length - 1];
    if (last) {
      const dir = path.join(ws, last);
      out += section(`summary run ${last} stderr`, await tail(path.join(dir, "last_stderr.log"), 20));
      out += section(`summary run ${last} stdout`, await tail(path.join(dir, "last_stdout.log"), 10));
    }
  } catch { /* no summaries run yet */ }
  out += section("last crash", await lastCrash());
  return out;
}

function safe(f: () => string): string {
  try { return f(); } catch { return "?"; }
}

/// Working set of Nikxel and of what it starts, so "it uses 1 GB" says which
/// part. WhatsApp Web runs inside Nikxel (its own hidden window), so it's
/// split out by the renderer process showing web.whatsapp.com.
async function memory(): Promise<string> {
  const mb: Record<string, number> = {};
  try {
    const waPids = new Set<number>();
    for (const wc of webContents.getAllWebContents()) {
      try { if (wc.getURL().includes("web.whatsapp.com")) waPids.add(wc.getOSProcessId()); } catch { /* destroyed */ }
    }
    for (const m of app.getAppMetrics()) {
      const key = waPids.has(m.pid) ? "whatsapp-browser" : "nikxel";
      mb[key] = (mb[key] ?? 0) + Math.round((m.memory?.workingSetSize ?? 0) / 1024);
    }
  } catch { /* not in Electron */ }
  if (process.platform === "win32") {
    const r = await powershell(
      "$s = (Get-Process -Name 'whisper*', 'main' -ErrorAction SilentlyContinue | Where-Object { $_.Path -match 'whisper' } | Measure-Object WorkingSet64 -Sum).Sum; if ($s) { [int]($s / 1MB) }",
      { timeoutMs: 15_000 });
    const w = parseInt(r.stdout.trim(), 10);
    if (Number.isFinite(w) && w > 0) mb.whisper = w;
  }
  return Object.keys(mb).sort().map(k => `${k}=${mb[k]}MB`).join(" ");
}

function section(name: string, body: string): string {
  return body === "" ? "" : `\n--- ${name} ---\n${body}\n`;
}

/// Last `n` lines. Reads at most the last 256 KB: debug.log grows without
/// bound and only its end matters.
async function tail(file: string, n: number): Promise<string> {
  let fh: fs.promises.FileHandle | null = null;
  try {
    fh = await fs.promises.open(file, "r");
    const size = (await fh.stat()).size;
    const len = Math.min(size, 256 * 1024);
    const buf = Buffer.alloc(len);
    await fh.read(buf, 0, len, size - len);
    const lines = buf.toString("utf8").split(/\r?\n/);
    return lines.slice(-n).join("\n").trim();
  } catch {
    return "";
  } finally {
    await fh?.close().catch(() => {});
  }
}

/// Newest crash dump Electron's crash reporter left, if any. Minidumps are
/// binary, so the report names it and when it happened; the user can send
/// the file itself if it's asked for.
async function lastCrash(): Promise<string> {
  let dir: string;
  try { dir = app.getPath("crashDumps"); } catch { return ""; }
  const found: { file: string; at: Date }[] = [];
  const walk = async (d: string, depth: number) => {
    let entries: fs.Dirent[];
    try { entries = await fs.promises.readdir(d, { withFileTypes: true }); } catch { return; }
    for (const e of entries) {
      const p = path.join(d, e.name);
      if (e.isDirectory() && depth < 2) await walk(p, depth + 1);
      else if (e.isFile() && e.name.endsWith(".dmp")) {
        try { found.push({ file: p, at: (await fs.promises.stat(p)).mtime }); } catch { /* vanished */ }
      }
    }
  };
  await walk(dir, 0);
  if (found.length === 0) return "";
  found.sort((a, b) => b.at.getTime() - a.at.getTime());
  return `${found[0].file}\n${found[0].at.toString()}\n(${found.length} dump${found.length === 1 ? "" : "s"} in ${dir})`;
}

export const SupportLogs = { report };
