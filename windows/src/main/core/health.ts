import { app, powerMonitor, screen, WebContents, webContents } from "electron";
import * as fs from "fs";
import * as os from "os";
import * as path from "path";
import { diag } from "./diag";
import { Settings } from "./settings";

/// What goes wrong in an Electron app without a trace, written to debug.log
/// under the "health" tag so Copy Logs carries it: errors in the main
/// process, JavaScript errors in every window, windows that crash or stop
/// answering, the GPU process dying, the main thread freezing, sleep, screen
/// changes, and every 10 minutes what each process costs. Started once,
/// first thing, from main.ts.

/// The same line from the same place is written once a minute at most, and a
/// window at most 60 lines an hour: a page that logs in a loop shouldn't push
/// everything else out of the log.
const seen = new Map<string, number>();
const budget = new Map<number, { hour: number; left: number }>();

function once(key: string, ms = 60_000): boolean {
  const now = Date.now(), last = seen.get(key) ?? 0;
  if (now - last < ms) return false;
  seen.set(key, now);
  if (seen.size > 500) seen.clear();
  return true;
}

function spend(wc: WebContents): boolean {
  const hour = Math.floor(Date.now() / 3_600_000);
  const b = budget.get(wc.id);
  if (!b || b.hour !== hour) { budget.set(wc.id, { hour, left: 59 }); return true; }
  return b.left-- > 0;
}

/// "avatar", "dashboard", "whatsapp", "summary: <file>"… from what the window shows.
export function label(wc: WebContents): string {
  try {
    const url = wc.getURL();
    if (/web\.whatsapp\.com/.test(url)) return "whatsapp";
    if (url.startsWith("file:")) {
      const file = decodeURIComponent(path.basename(new URL(url).pathname)).replace(/\.html$/, "");
      return /renderer$/.test(path.dirname(decodeURIComponent(new URL(url).pathname))) ? file : `summary: ${file}`;
    }
    return url ? new URL(url).host || url.slice(0, 40) : `contents ${wc.id}`;
  } catch { return `contents ${wc.id}`; }
}

function log(msg: string): void { diag("health", msg); }

export function start(): void {
  banner();

  // Main process: an uncaught error used to end in Electron's dialog or a
  // silent stop. Logged with its stack, and Nikxel carries on.
  process.on("uncaughtException", e => log(`main uncaught: ${e?.stack ?? e}`));
  process.on("unhandledRejection", r => {
    const s = r instanceof Error ? r.stack ?? r.message : String(r);
    if (once(`rej:${s.slice(0, 200)}`)) log(`main unhandled rejection: ${s}`);
  });

  app.on("child-process-gone", (_e, d) =>
    log(`child process gone: ${d.type}${d.name ? ` (${d.name})` : ""} — ${d.reason}, exit ${d.exitCode}`));
  app.on("render-process-gone", (_e, wc, d) => log(`window crashed: ${label(wc)} — ${d.reason}, exit ${d.exitCode}`));
  app.on("web-contents-created", (_e, wc) => watch(wc));

  powerMonitor.on("suspend", () => log("sleep"));
  powerMonitor.on("resume", () => log("wake"));
  powerMonitor.on("lock-screen", () => log("screen locked"));
  powerMonitor.on("unlock-screen", () => log("screen unlocked"));
  app.whenReady().then(() => {
    // The avatar's position and click-through depend on these.
    screen.on("display-added", (_e, d) => log(`display added: ${display(d)}`));
    screen.on("display-removed", (_e, d) => log(`display removed: ${display(d)}`));
    screen.on("display-metrics-changed", (_e, d, changed) => log(`display changed (${changed.join(", ")}): ${display(d)}`));
  }).catch(() => {});

  watchMainThread();
  setInterval(sample, 10 * 60_000).unref();
  setTimeout(sample, 60_000).unref();
}

function watch(wc: WebContents): void {
  // Errors and warnings from the page. WhatsApp Web's own console is noise;
  // only its crashes and hangs are logged.
  wc.on("console-message", (...args: unknown[]) => {
    const e = args[0] as { level?: string; message?: string; lineNumber?: number; sourceId?: string };
    // Electron 35+ puts the details on the event; older ones passed them as arguments.
    const level = typeof e.level === "string" ? e.level : ["verbose", "info", "warning", "error"][Number(args[1])] ?? "info";
    const message = e.message ?? String(args[2] ?? "");
    const line = e.lineNumber ?? Number(args[3] ?? 0);
    const source = e.sourceId ?? String(args[4] ?? "");
    if (level !== "error" && level !== "warning") return;
    const who = label(wc);
    // Electron's own security notice only shows in builds run from source.
    if (who === "whatsapp" || message.includes("Electron Security Warning")) return;
    const where = source ? ` (${path.basename(source)}:${line})` : "";
    if (once(`${who}|${message}|${where}`) && spend(wc)) log(`${who} ${level}: ${message.replace(/\s*\n\s*/g, " ⏎ ").slice(0, 600)}${where}`);
  });
  wc.on("unresponsive", () => log(`window not responding: ${label(wc)}`));
  wc.on("responsive", () => log(`window responding again: ${label(wc)}`));
  wc.on("preload-error", (_e, file, err) => log(`preload failed: ${label(wc)} ${path.basename(file)} — ${err?.stack ?? err}`));
  wc.on("did-fail-load", (_e, code, desc, url, isMain) => {
    // -3 is a navigation the app cancelled on purpose (links out, tab swaps).
    if (code !== -3 && isMain) log(`load failed: ${label(wc)} ${url} — ${desc} (${code})`);
  });
}

/// The main thread stalling (a sync file read, a long JSON parse, a busy
/// loop) is what makes every window feel stuck at once. A 1 s timer that
/// fires late says by how much.
function watchMainThread(): void {
  let expected = Date.now() + 1000;
  setInterval(() => {
    const late = Date.now() - expected;
    expected = Date.now() + 1000;
    // Waking from sleep looks like a huge stall; that one is logged as "wake".
    if (late > 750 && late < 120_000 && once(`stall:${Math.round(late / 1000)}`, 10_000)) {
      log(`main thread stalled ${(late / 1000).toFixed(1)} s`);
    }
  }, 1000).unref();
}

/// CPU and memory per process, named by what each window shows.
function sample(): void {
  try {
    const byPid = new Map<number, string>();
    for (const wc of webContents.getAllWebContents()) {
      try { byPid.set(wc.getOSProcessId(), label(wc)); } catch { /* destroyed */ }
    }
    let cpu = 0, mem = 0;
    const parts = app.getAppMetrics().map(m => {
      const mb = Math.round((m.memory?.workingSetSize ?? 0) / 1024);
      cpu += m.cpu.percentCPUUsage; mem += mb;
      const name = m.type === "Tab" ? byPid.get(m.pid) ?? "tab" : m.type === "Browser" ? "main" : m.type.toLowerCase();
      return `${name} ${mb}MB ${m.cpu.percentCPUUsage.toFixed(1)}%`;
    });
    log(`usage: ${mem}MB, ${cpu.toFixed(1)}% CPU — ${parts.join(", ")}`);
  } catch (e) { log(`usage sample failed: ${e}`); }
}

function display(d: Electron.Display): string {
  return `${d.size.width}x${d.size.height} @${d.scaleFactor}x at ${d.bounds.x},${d.bounds.y}`;
}

/// What this run is, once at launch: the first thing to check in any report.
function banner(): void {
  let commit = "";
  try { commit = fs.readFileSync(path.join(__dirname, "..", "..", "commit"), "utf8").trim().slice(0, 7); } catch { /* hand build */ }
  log(`---- Nikxel ${app.getVersion()}${commit ? ` (${commit})` : ""} ${app.isPackaged ? "installed" : "from source"} · ` +
      `Electron ${process.versions.electron} · Windows ${os.release()} ${os.arch()} · ${Math.round(os.totalmem() / 2 ** 30)} GB RAM · ` +
      `agent ${Settings.connectedAgent}, capture ${Settings.captureMode}, WhatsApp ${Settings.whatsappConnected ? `connected (${Settings.waBotMode}${Settings.botEnabled ? "" : ", off"})` : "not connected"}`);
  app.whenReady().then(() => {
    log(`displays: ${screen.getAllDisplays().map(display).join(" | ")}`);
  }).catch(() => {});
}
