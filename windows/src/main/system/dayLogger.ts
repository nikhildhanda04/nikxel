import * as fs from "fs";
import * as path from "path";
import { Worker } from "worker_threads";
import { HOME, isWin, documentsDir, dayStamp, ensureDir, readText } from "../core/paths";
import { Settings } from "../core/settings";
import { run, which } from "../core/proc";
import { diag, cblog } from "../core/diag";
import { bus } from "../core/bus";
import type { MOMGenerator } from "../recording/momGenerator";
import { WhatsAppActivityLogger } from "../whatsapp/whatsAppActivityLogger";
import { DayPage } from "./dayPage";
import { desktopRequest } from "./desktopHelper";

/// The handful of numbers worth putting in a bubble. Separate from the
/// narrative summary, which is prose and takes an agent run to produce.
export interface DayStats {
  codingSeconds: number;
  /// All sampled foreground time, coding or not.
  activeSeconds: number;
  meetings: number;
  messages: number;
}

export function emptyStats(s: Partial<DayStats> = {}): DayStats {
  return { codingSeconds: 0, activeSeconds: 0, meetings: 0, messages: 0, ...s };
}

const SAMPLE_INTERVAL = 15;
// Cap each sample's attributed duration so a sleep-through-the-night gap
// doesn't get charged to whatever app was foreground when the lid closed.
const DURATION_CAP = 5 * 60;
// Fire EOD summary at this hour (24h). 22 = 10pm.
const SUMMARY_HOUR = 22;
/// `aggregateGit` shells out to git once per repo under the projects root,
/// and a busy chat can ask for this several times a minute. Ten minutes is
/// still "what are you working on right now".
const LIVE_CACHE_TTL = 600_000;
/// Past this, the slow half of the live context (git, agent prompts) is too
/// old to call "right now" and is left out until the refresh lands.
const LIVE_STALE_LIMIT = 30 * 60_000;

const hhmm = (d: Date) => `${String(d.getHours()).padStart(2, "0")}:${String(d.getMinutes()).padStart(2, "0")}`;

/// Where the per-day sample logs live: the Mac's
/// ~/Library/Application Support/Nikxel/days, i.e. %APPDATA%\Nikxel\days.
function logDirectory(): string {
  if (isWin) return path.join(process.env.APPDATA ?? path.join(HOME, "AppData", "Roaming"), "Nikxel", "days");
  return path.join(HOME, "Library", "Application Support", "Nikxel", "days");
}

/// Runs `n` async jobs at most `limit` at a time. Swift used
/// concurrentPerform; spawning git for 30 repos x 5 calls at once is a
/// process storm on Windows, where each spawn is far dearer.
async function mapLimit<T, R>(items: T[], limit: number, fn: (t: T, i: number) => Promise<R>): Promise<R[]> {
  const out = new Array<R>(items.length);
  let next = 0;
  const worker = async () => {
    while (next < items.length) {
      const i = next++;
      out[i] = await fn(items[i], i);
    }
  };
  await Promise.all(Array.from({ length: Math.min(limit, items.length) }, worker));
  return out;
}

const truncate = (s: string, n: number) => {
  const chars = Array.from(s);
  return chars.length > n ? chars.slice(0, n).join("") + "…" : s;
};
const prefix = (s: string, n: number) => Array.from(s).slice(0, n).join("");

export class DayLogger {
  /// The one instance, so LLMResponder can ask what today looks like without
  /// main.ts threading a reference through MOMGenerator into the chatbot.
  static current: DayLogger | null = null;

  private readonly logDir: string;
  private readonly summaryDir: string;
  private readonly meetingsDir: string;
  private sampleTimer: NodeJS.Timeout | null = null;
  private summaryTimer: NodeJS.Timeout | null = null;
  private lastSample: { app: string; title: string } | null = null;
  private sampling = false;
  /// Days whose summary is being written right now, so the 10pm timer and a
  /// wake-time backfill can't both start one.
  private generating = new Set<string>();
  private readonly onWake = () => { this.scheduleSummary(); this.backfillIfMissed(); };

  /// Fired right after an end-of-day summary is written, with the one-line
  /// digest for the avatar bubble and the file it came from.
  onSummaryReady: ((line: string, filePath: string) => void) | null = null;

  constructor(private readonly momGenerator: MOMGenerator) {
    this.logDir = ensureDir(logDirectory());
    this.summaryDir = DayLogger.summaryDirectory;
    this.meetingsDir = documentsDir("meetings");
    DayLogger.current = this;
  }

  start(): void {
    this.sample();
    this.sampleTimer = setInterval(() => this.sample(), SAMPLE_INTERVAL * 1000);
    this.scheduleSummary();
    this.backfillIfMissed();
    // Wakes are when a missed 10pm is noticed, and when a timer that slept
    // through its fire time needs re-aiming.
    bus.on("wake", this.onWake);
    // Warm the slow half of the live context, so the bot's first reply of
    // the day already knows what's in hand -- only when there is a bot to
    // reply: it's a repo walk and dozens of git runs.
    setTimeout(() => {
      if (Settings.whatsappConnected && Settings.botEnabled && Settings.waWorkContext) this.refreshLiveSlow();
    }, 20_000);
  }

  stop(): void {
    if (this.sampleTimer) clearInterval(this.sampleTimer);
    if (this.summaryTimer) clearTimeout(this.summaryTimer);
    this.sampleTimer = null; this.summaryTimer = null;
    bus.off("wake", this.onWake);
  }

  generateSummaryNow(): void {
    this.generateSummary(new Date());
  }

  // MARK: - Digest

  /// Frontmost-app names that count as coding. Matched as lowercase
  /// substrings, so "Visual Studio Code", "Code - Insiders" and "VSCodium"
  /// all land on "code". The second half are the Windows names: the
  /// executable's file description ("Windows PowerShell", "IntelliJ IDEA")
  /// or, when it has none, the exe name ("idea64", "WindowsTerminal").
  static readonly codingAppHints = [
    "code", "xcode", "vscodium", "cursor", "zed", "windsurf", "fleet",
    "terminal", "iterm", "ghostty", "warp", "alacritty", "kitty", "hyper", "wezterm",
    "sublime", "nova", "textmate", "neovim", "emacs",
    "android studio", "intellij", "pycharm", "webstorm", "goland", "phpstorm",
    "rubymine", "clion", "rider", "datagrip",
    "antigravity", "kiro",
    // Windows
    "powershell", "pwsh", "command prompt", "windows command processor", "console window host",
    "visual studio", "devenv", "idea64", "notepad++", "mintty", "git bash", "wsl", "ubuntu",
  ];

  static isCodingApp(name: string): boolean {
    const n = name.toLowerCase();
    return DayLogger.codingAppHints.some(h => n.includes(h));
  }

  /// Formats stats into the bubble's single line. null when the day is empty
  /// enough that a bubble would say nothing -- better no bubble than
  /// "0 meetings". Pure; see checks/dayDigest.test.ts.
  static digestLine(s: DayStats): string | null {
    const parts: string[] = [];
    const codingMins = Math.round(s.codingSeconds / 60);
    if (codingMins >= 1) parts.push(`${DayLogger.humanDuration(codingMins)} coding`);
    if (s.meetings > 0) parts.push(`${s.meetings} meeting${s.meetings === 1 ? "" : "s"}`);
    if (s.messages > 0) parts.push(`${s.messages} message${s.messages === 1 ? "" : "s"}`);
    if (parts.length) return parts.join(" · ");

    // Nothing headline-worthy, but the PC was clearly in use -- say that
    // rather than showing an empty bubble. Under half an hour, say nothing.
    const activeMins = Math.floor(s.activeSeconds / 60);
    if (activeMins >= 30) return `${DayLogger.humanDuration(activeMins)} at the PC`;
    return null;
  }

  /// 200 -> "3h 20m", 45 -> "45m", 120 -> "2h".
  /// New messages seen in the chat log. It holds a preview snapshot of every
  /// chat on each poll, so counting lines counted snapshots (thousands a day).
  /// A chat's first sighting is what was already there; after that each
  /// preview it hadn't shown before is one new message. Seen-before, not just
  /// changed: previews flip between "typing…" and back all day.
  static countMessages(entries: { name?: unknown; preview?: unknown }[]): number {
    const seen = new Map<unknown, Set<unknown>>();
    let n = 0;
    for (const e of entries) {
      const s = seen.get(e.name);
      if (!s) { seen.set(e.name, new Set([e.preview])); continue; }
      if (!s.has(e.preview)) { s.add(e.preview); n += 1; }
    }
    return n;
  }

  static humanDuration(minutes: number): string {
    const h = Math.floor(minutes / 60), m = minutes % 60;
    if (h === 0) return `${m}m`;
    if (m === 0) return `${h}h`;
    return `${h}h ${m}m`;
  }

  private readSamples(date: Date): { t: number; app: string; title: string }[] {
    const content = readText(this.logFile(date));
    if (!content) return [];
    const samples: { t: number; app: string; title: string }[] = [];
    for (const line of content.split("\n")) {
      if (!line.trim()) continue;
      try {
        const obj = JSON.parse(line);
        if (typeof obj.t !== "number" || typeof obj.app !== "string") continue;
        samples.push({ t: obj.t, app: obj.app, title: typeof obj.title === "string" ? obj.title : "" });
      } catch { /* torn line */ }
    }
    return samples;
  }

  /// Counts the day's coding time, meetings and WhatsApp messages off the
  /// same logs the narrative summary is built from.
  dayStats(date: Date): DayStats {
    const stats = emptyStats();

    // Foreground time, attributed the same way aggregateAppUsage does it:
    // each sample owns the gap until the next one, capped so a lid-closed
    // overnight gap isn't charged to whatever was open.
    const samples = this.readSamples(date).sort((a, b) => a.t - b.t);
    samples.forEach((s, i) => {
      const dur = i + 1 < samples.length ? Math.min(samples[i + 1].t - s.t, DURATION_CAP) : SAMPLE_INTERVAL;
      stats.activeSeconds += dur;
      if (DayLogger.isCodingApp(s.app)) stats.codingSeconds += dur;
    });

    // Meetings: the day's generated MOMs. ".transcript.txt" is excluded by
    // the .md check, so a meeting is never counted twice.
    try {
      const key = dayStamp(date);
      stats.meetings = fs.readdirSync(this.meetingsDir).filter(f => f.startsWith(key) && f.endsWith(".md")).length;
    } catch { /* no meetings folder yet */ }

    stats.messages = DayLogger.countMessages(safeReadLog("chats", date));
    return stats;
  }

  // MARK: - Live context

  /// The slow half (git, agent prompts), refreshed in the background. The
  /// Mac computed everything inline on a background thread; here the API is
  /// synchronous and git is a process away, so the cheap lines are built on
  /// every call and the expensive ones come from this cache.
  private liveSlow: { lines: string[]; at: number } | null = null;
  private liveRefreshing: Promise<void> | null = null;

  /// What the user is doing right now and what today has looked like so far,
  /// as a few short lines. Fills the gap the end-of-day summaries leave: until
  /// 10pm, the whole current day is invisible to the WhatsApp bot, which is
  /// exactly the day someone is most likely to be asking about.
  liveContext(inMeeting: boolean): string {
    const now = Date.now();
    if (!this.liveSlow || now - this.liveSlow.at >= LIVE_CACHE_TTL) this.refreshLiveSlow();
    const slow = this.liveSlow && now - this.liveSlow.at < LIVE_STALE_LIMIT ? this.liveSlow.lines : [];
    return this.liveFast(inMeeting).concat(slow).join("\n");
  }

  /// liveContext, but waits for the git/prompt half to be fresh first. For
  /// callers that can await; the bot's first reply after a quiet spell gets
  /// the whole picture this way.
  async liveContextAsync(inMeeting: boolean): Promise<string> {
    if (!this.liveSlow || Date.now() - this.liveSlow.at >= LIVE_CACHE_TTL) await this.refreshLiveSlow();
    return this.liveContext(inMeeting);
  }

  /// The meeting flag is computed fresh every time, not cached: a meeting can
  /// start or end inside the TTL, and "in a meeting right now" is the one
  /// line in here the bot is allowed to repeat out loud.
  private liveFast(inMeeting: boolean): string[] {
    const lines: string[] = [];
    lines.push(inMeeting ? "- In a meeting right now." : "- Not in a meeting right now.");

    if (this.lastSample) {
      const title = this.lastSample.title.trim();
      lines.push(title === ""
        ? `- Currently in: ${this.lastSample.app}`
        : `- Currently in: ${this.lastSample.app} — "${prefix(title, 90)}"`);
    }

    const digest = DayLogger.digestLine(this.dayStats(new Date()));
    if (digest) lines.push(`- Today so far: ${digest}`);

    const windows = this.recentWindows(8);
    if (windows.length) {
      lines.push("- Recently open (newest first):\n" + windows.map(w => "  " + w).join("\n"));
    }
    return lines;
  }

  private refreshLiveSlow(): Promise<void> {
    if (this.liveRefreshing) return this.liveRefreshing;
    this.liveRefreshing = (async () => {
      try {
        const lines: string[] = [];
        const repos = await this.findRepos();
        const [edits, week, claude, opencode] = await Promise.all([
          this.todaysEdits(repos),
          this.recentWork(repos, 7),
          this.aggregateClaudeSessions(new Date()),
          this.aggregateOpencodeSessions(new Date()),
        ]);
        if (edits) {
          lines.push("- Code today, most recently touched project first:\n" +
            edits.split("\n").slice(0, 50).map(l => "  " + l).join("\n"));
        }
        if (week) {
          lines.push("- Projects active this week (latest commits first):\n" +
            week.split("\n").slice(0, 60).map(l => "  " + l).join("\n"));
        }
        // The literal asks made to coding agents today -- the clearest record
        // of which feature or bug is in hand, and the one thing git can't show
        // until it's committed.
        const asks = (claude + "\n" + opencode).split("\n").filter(l => l !== "").slice(-15)
          .map(l => "  " + DayLogger.redactSecrets(truncate(l, 180)));
        if (asks.length) lines.push("- Asked AI agents today (latest last):\n" + asks.join("\n"));
        this.liveSlow = { lines, at: Date.now() };
      } catch (e) {
        diag("DayLogger", `live context refresh failed: ${e}`);
      } finally {
        this.liveRefreshing = null;
      }
    })();
    return this.liveRefreshing;
  }

  /// Prompts get pasted tokens and keys; none of that belongs in a prompt that
  /// writes messages to other people. Long unbroken alphanumeric runs (API
  /// tokens, keys, hashes) and the paste wrapper tag are dropped.
  static redactSecrets(s: string): string {
    return s.replace(/<pasted_content[^>]*>/g, "").replace(/[A-Za-z0-9_\-]{16,}/g, "[redacted]");
  }

  /// The last few distinct windows from today's samples, newest first --
  /// documents, PRs, tickets, whatever the titles name.
  private recentWindows(limit: number): string[] {
    const samples = this.readSamples(new Date());
    const seen = new Set<string>(), out: string[] = [];
    for (let i = samples.length - 1; i >= 0; i--) {
      const title = samples[i].title.trim();
      const entry = title === "" ? samples[i].app : `${samples[i].app} — ${prefix(title, 90)}`;
      if (!seen.has(entry)) { seen.add(entry); out.push(entry); }
      if (out.length === limit) break;
    }
    return out;
  }

  // MARK: - Sampling

  /// Foreground app + window title, from a long-lived PowerShell helper so the
  /// 15 s sampler doesn't start a process each tick. Windows needs no
  /// permission for either (the Mac needed Accessibility for titles).
  private async sample(): Promise<void> {
    if (this.sampling) return;
    this.sampling = true;
    try {
      const fg = await this.foreground();
      if (!fg) return;
      if (this.lastSample && this.lastSample.app === fg.app && this.lastSample.title === fg.title) return;
      this.lastSample = fg;
      this.appendLog({ t: Date.now() / 1000, app: fg.app, title: fg.title });
    } finally {
      this.sampling = false;
    }
  }

  private async foreground(): Promise<{ app: string; title: string } | null> {
    if (!isWin) return null;
    const out = await desktopRequest("fg", 20_000);
    if (!out) return null;
    try {
      const obj = JSON.parse(out);
      const app = typeof obj.app === "string" && obj.app.trim() ? obj.app.trim() : "";
      if (!app) return null;
      return { app, title: typeof obj.title === "string" ? obj.title : "" };
    } catch {
      return null;
    }
  }

  private appendLog(entry: { t: number; app: string; title: string }): void {
    fs.promises.appendFile(this.logFile(new Date()), JSON.stringify(entry) + "\n")
      .catch(e => diag("DayLogger", `couldn't append sample: ${e}`));
  }

  private logFile(date: Date): string {
    return path.join(this.logDir, `${dayStamp(date)}.jsonl`);
  }

  private summaryFile(date: Date): string {
    return path.join(this.summaryDir, `${dayStamp(date)}.md`);
  }

  /// Where the end-of-day summaries live. Static so the WhatsApp bot can
  /// read them back without owning a DayLogger.
  static get summaryDirectory(): string {
    return documentsDir("daily");
  }

  /// The most recent `days` end-of-day summaries, newest first, skipping
  /// days with no summary (the app wasn't running, or it's before 10pm).
  ///
  /// Each is truncated: a full day's summary runs to a few KB, and this gets
  /// prepended to every WhatsApp reply prompt, where it would otherwise
  /// dominate the actual message and slow every response down.
  /// `directory` and `now` are injectable so this can be checked against a
  /// temp folder and a fixed date -- see checks/botMemory.test.ts.
  static recentSummaryEntries(days: number, maxCharsPerDay = 1200, directory?: string, now: Date = new Date()): { day: string; text: string }[] {
    if (!(days > 0)) return [];
    let dir: string;
    try { dir = directory ?? DayLogger.summaryDirectory; } catch { return []; }
    const out: { day: string; text: string }[] = [];
    // Start at yesterday: today's summary doesn't exist until 10pm, and
    // looking back `days` from today would silently give one day fewer.
    for (let offset = 1; offset <= days; offset++) {
      const date = new Date(now.getFullYear(), now.getMonth(), now.getDate() - offset, now.getHours());
      const key = dayStamp(date);
      const raw = readText(path.join(dir, `${key}.md`));
      if (raw === null) continue;
      const text = raw.trim();
      if (text === "") continue;
      out.push({ day: key, text: truncate(text, maxCharsPerDay) });
    }
    return out;
  }

  /// The same summaries as one block, ready to drop into a prompt: each day
  /// under a `--- yyyy-MM-dd ---` header, newest first, exactly as
  /// LLMResponder.recentContextBlock laid out the Mac's tuples. "" when there
  /// are none.
  static recentSummaries(days: number): string {
    return DayLogger.recentSummaryEntries(days).map(e => `--- ${e.day} ---\n${e.text}\n\n`).join("");
  }

  // MARK: - Scheduling

  private nextSummaryFireDate(after: Date): Date {
    const today = new Date(after.getFullYear(), after.getMonth(), after.getDate(), SUMMARY_HOUR, 0, 0);
    if (today > after) return today;
    return new Date(after.getFullYear(), after.getMonth(), after.getDate() + 1, SUMMARY_HOUR, 0, 0);
  }

  private scheduleSummary(): void {
    if (this.summaryTimer) clearTimeout(this.summaryTimer);
    const fire = this.nextSummaryFireDate(new Date());
    const interval = Math.max(1000, fire.getTime() - Date.now());
    this.summaryTimer = setTimeout(() => {
      this.generateSummary(new Date());
      this.scheduleSummary();
    }, interval);
  }

  /// Idempotent: writes today's summary if past the summary hour and the
  /// file isn't there yet. Safe to call from app launch, wake-from-sleep,
  /// and external triggers.
  backfillIfMissed(): void {
    const now = new Date();
    const todayFire = new Date(now.getFullYear(), now.getMonth(), now.getDate(), SUMMARY_HOUR, 0, 0);
    if (now < todayFire) return;
    if (fs.existsSync(this.summaryFile(now))) return;
    this.generateSummary(now);
  }

  // MARK: - Aggregation

  private generateSummary(date: Date): void {
    const key = dayStamp(date);
    if (this.generating.has(key)) return;
    this.generating.add(key);
    (async () => {
      try {
        const report = await this.buildReport(date);
        if (report === "") return;
        const prompt = this.summaryPrompt(report, date);
        const output = await this.momGenerator.runPrompt(prompt, "daily-summary");
        const file = this.summaryFile(date);
        await fs.promises.writeFile(file, output, "utf8");
        // The .md stays: it's what the WhatsApp bot's memory reads back.
        const stats = this.dayStats(date);
        const page = file.replace(/\.md$/, ".html");
        await fs.promises.writeFile(page, DayPage.html(output, stats), "utf8");
        const line = DayLogger.digestLine(stats);
        if (line) this.onSummaryReady?.(line, page);
      } catch (e) {
        diag("DayLogger", `summary generation failed: ${e instanceof Error ? e.message : e}`);
      } finally {
        this.generating.delete(key);
      }
    })();
  }

  private async buildReport(date: Date): Promise<string> {
    const parts: string[] = [];
    const usage = this.aggregateAppUsage(date);
    if (usage) parts.push("## App usage (sampled every 15s)\n" + usage);
    const meetings = await this.aggregateMeetings(date);
    if (meetings) parts.push("## Meetings\n" + meetings);
    const git = await this.aggregateGit(date);
    if (git) parts.push("## Git activity\n" + git);
    const claudePrompts = await this.aggregateClaudeSessions(date);
    if (claudePrompts) parts.push("## Claude Code sessions (your prompts today)\n" + claudePrompts);
    const opencodePrompts = await this.aggregateOpencodeSessions(date);
    if (opencodePrompts) parts.push("## Opencode sessions (your prompts today)\n" + opencodePrompts);
    const waChats = this.aggregateWhatsAppChats(date);
    if (waChats) parts.push("## WhatsApp chats (preview snapshots through the day)\n" + waChats);
    const waCalls = this.aggregateWhatsAppCalls(date);
    if (waCalls) parts.push("## WhatsApp calls\n" + waCalls);
    return parts.join("\n\n");
  }

  private aggregateAppUsage(date: Date): string | null {
    const samples = this.readSamples(date);
    if (samples.length === 0) return null;
    samples.sort((a, b) => a.t - b.t);

    const appDurations = new Map<string, number>();
    const appTitles = new Map<string, Map<string, number>>();
    samples.forEach((s, i) => {
      const dur = i + 1 < samples.length ? Math.min(samples[i + 1].t - s.t, DURATION_CAP) : SAMPLE_INTERVAL;
      appDurations.set(s.app, (appDurations.get(s.app) ?? 0) + dur);
      if (s.title !== "") {
        const titles = appTitles.get(s.app) ?? new Map<string, number>();
        titles.set(s.title, (titles.get(s.title) ?? 0) + dur);
        appTitles.set(s.app, titles);
      }
    });

    const lines: string[] = [];
    for (const [app, dur] of [...appDurations].sort((a, b) => b[1] - a[1])) {
      const mins = Math.floor(dur / 60);
      if (mins < 1) continue;
      lines.push(`- ${app}: ${mins} min`);
      const titles = appTitles.get(app);
      if (titles) {
        for (const [title, td] of [...titles].sort((a, b) => b[1] - a[1]).slice(0, 3)) {
          const tm = Math.floor(td / 60);
          if (tm < 1) continue;
          lines.push(`  - "${title}" (${tm} min)`);
        }
      }
    }
    return lines.join("\n");
  }

  private async aggregateMeetings(date: Date): Promise<string> {
    let files: string[];
    try { files = await fs.promises.readdir(this.meetingsDir); } catch { return ""; }
    const key = dayStamp(date);
    const today = files.filter(f => f.startsWith(key) && path.extname(f) === ".md").sort();
    if (today.length === 0) return "";
    const lines: string[] = [];
    for (const f of today) {
      const stem = path.basename(f, ".md");
      // Stem format: yyyy-MM-dd-HHmmss (or the Windows-safe
      // yyyy-MM-dd_HH-mm-ss that fileStamp() produces).
      const m = stem.match(/^\d{4}-\d{2}-\d{2}[-_](\d{2})-?(\d{2})-?\d{2}/);
      const time = m ? `${m[1]}:${m[2]}` : "?";
      // Pull the Summary section out of the MOM, if present, to give the LLM something to anchor on.
      let blurb = "";
      try {
        const content = await fs.promises.readFile(path.join(this.meetingsDir, f), "utf8");
        blurb = extractSection(content, "Summary") ?? "";
      } catch { /* unreadable: list it bare */ }
      lines.push(blurb === "" ? `- ${time} — ${f}` : `- ${time} — ${f}\n  ${blurb.replace(/\n/g, "\n  ")}`);
    }
    return lines.join("\n");
  }

  /// Directory names never worth walking into when hunting for repos. Without
  /// this the scan descends every `node_modules` in full -- hundreds of
  /// thousands of files across a handful of JS projects -- and surfaces
  /// vendored `.git` directories as if they were the user's own work.
  static readonly skipWhileScanning = new Set([
    "node_modules", "Pods", "DerivedData", "vendor", "target",
    "build", "dist", ".build", ".next", ".nuxt", ".cache",
    "venv", ".venv", "__pycache__", "Library", "Applications",
    // Windows
    "AppData", "$RECYCLE.BIN", "System Volume Information", "bin", "obj",
  ]);

  private reposCache: { root: string; repos: string[]; at: number } | null = null;

  /// The tree walk is the slow half of every git pass, and new clones are
  /// rare: an hour-old list is fine.
  private async findRepos(): Promise<string[]> {
    const root = Settings.projectsRoot;
    const c = this.reposCache;
    if (c && c.root === root && Date.now() - c.at < 3_600_000) return c.repos;
    const repos = await this.scanRepos();
    this.reposCache = { root, repos, at: Date.now() };
    return repos;
  }

  private async scanRepos(): Promise<string[]> {
    const scanRoot = Settings.projectsRoot;
    const repoDirs: string[] = [];
    // `.git` is itself hidden, so hidden entries are checked for it before
    // being skipped. It's a directory in a clone and a file in a worktree or
    // submodule; both mark a repo. Links/junctions aren't followed, like the
    // Mac's enumerator.
    const walk = async (dir: string, depth: number): Promise<void> => {
      if (depth > 12) return;
      let entries: fs.Dirent[];
      try { entries = await fs.promises.readdir(dir, { withFileTypes: true }); } catch { return; }
      // Keep walking inside a repo: one nested in another
      // (projects/nikxel/website/nikxel-site) is still its own project.
      if (entries.some(e => e.name === ".git")) repoDirs.push(dir);
      await Promise.all(entries
        .filter(e => e.isDirectory() && !e.name.startsWith(".") && !DayLogger.skipWhileScanning.has(e.name))
        .map(e => walk(path.join(dir, e.name), depth + 1)));
    };
    await walk(scanRoot, 0);
    if (repoDirs.length === 0) {
      // Distinguishable in the log from "found repos, nothing happened
      // today". An empty scan usually means the root is wrong (see
      // `projectsRoot`), or that Windows Security's Controlled folder
      // access is refusing to let Nikxel list that folder.
      cblog(`DayLogger: no git repos under ${scanRoot} — check projectsRoot in ~/.nikxel/settings.json`);
    } else {
      cblog(`DayLogger: scanned ${scanRoot} — ${repoDirs.length} repo(s)`);
    }
    return repoDirs.sort();
  }

  /// Repos committed to in the last `days` days, quiet today or not: the
  /// current branch, the branches most recently worked on, and the last few
  /// commits. Today's git activity alone can't answer "any update on the
  /// Datacap task?" when that work sat on a branch two days ago.
  private async recentWork(repos: string[], days: number): Promise<string> {
    const blocks = await mapLimit(repos, 6, async repo => {
      const commits = await this.runGit(repo, ["log", "--branches", "--remotes", "-6", `--since=${days}.days`, "--pretty=format:%cr: %s"]);
      if (!commits) return "";
      const branch = await this.runGit(repo, ["branch", "--show-current"]);
      const branches = (await this.runGit(repo, ["for-each-ref", "--sort=-committerdate", "--count=4",
        "--format=%(refname:short)", "refs/heads"])).split("\n").filter(Boolean).join(", ");
      return `### ${path.basename(repo)} (on ${branch || "?"}; recent branches: ${branches})\n` +
        commits.split("\n").map(l => "  " + l).join("\n");
    });
    return blocks.filter(b => b !== "").join("\n");
  }

  /// Files that churn without being anyone's work.
  static isNoiseFile(p: string): boolean {
    const name = p.split(/[\\/]/).pop() ?? p;
    return name === ".DS_Store" || name === "Thumbs.db" || name === "desktop.ini"
      || name.endsWith(".lock") || name.endsWith("-lock.json")
      || name === "pnpm-lock.yaml" || name === "yarn.lock";
  }

  /// The function or block a `git diff` hunk sits in, from its `@@` header:
  /// `@@ -1,2 +1,3 @@ export function buildSaleBody(` -> `export function buildSaleBody(`.
  static hunkContexts(diff: string, limit = 4): string[] {
    const out: string[] = [];
    for (const line of diff.split("\n")) {
      if (!line.startsWith("@@")) continue;
      const parts = line.split("@@");
      if (parts.length < 3) continue;
      const ctx = parts.slice(2).join("@@").trim();
      if (ctx !== "" && !out.includes(ctx)) out.push(prefix(ctx, 80));
      if (out.length === limit) break;
    }
    return out;
  }

  /// For the bot: what was actually worked on today, per repo -- commits
  /// since midnight, and uncommitted files whose modification time is today
  /// (a raw `git status` also lists week-old leftovers and lockfiles), each
  /// with the functions its diff touches. Repos sort by latest edit, so the
  /// thing in hand right now is what survives the prompt cap.
  private async todaysEdits(repos: string[]): Promise<string> {
    const now = new Date();
    const dayStart = new Date(now.getFullYear(), now.getMonth(), now.getDate()).getTime();
    const blocks = await mapLimit(repos, 6, async repo => {
      // Every branch, local and remote: work committed and pushed from a
      // branch other than the checked-out one is still today's work.
      const commits = await this.runGit(repo, ["log", "--branches", "--remotes", "--since=midnight", "--pretty=format:%ct %h %s"]);
      const files: { at: number; path: string }[] = [];
      for (const line of (await this.runGit(repo, ["status", "--porcelain", "--untracked-files=all"])).split("\n")) {
        if (line.length <= 3) continue;
        const raw = line.slice(3);
        const p = raw.split(" -> ").pop() ?? raw;
        if (DayLogger.isNoiseFile(p)) continue;
        try {
          const m = (await fs.promises.stat(path.join(repo, p))).mtimeMs;
          if (m >= dayStart) files.push({ at: m, path: p });
        } catch { /* deleted, or a quoted path */ }
      }
      if (!commits && files.length === 0) return null;
      files.sort((a, b) => b.at - a.at);
      const commitLines = commits ? commits.split("\n") : [];
      const firstTs = commitLines.length ? parseFloat(commitLines[0].split(" ")[0]) : NaN;
      const lastCommit = Number.isFinite(firstTs) ? firstTs * 1000 : dayStart;
      const branch = await this.runGit(repo, ["branch", "--show-current"]);
      const out = [`### ${path.basename(repo)} (on ${branch || "?"})`];
      if (commitLines.length) {
        out.push("Committed today (newest first):");
        for (const line of commitLines.slice(0, 8)) {
          const sp = line.indexOf(" ");
          const hashAndSubject = sp >= 0 ? line.slice(sp + 1) : "";
          const hash = hashAndSubject.split(" ")[0];
          const remotes = (await this.runGit(repo, ["branch", "-r", "--contains", hash, "--format=%(refname:short)"]))
            .split("\n").filter(r => r !== "" && !r.endsWith("/HEAD"));
          out.push("  " + hashAndSubject + (remotes.length === 0 ? " — local only, not pushed"
            : " — pushed to " + remotes.slice(0, 3).join(", ")));
        }
      }
      if (files.length) {
        out.push("Edited today, not committed yet (newest first):");
        for (const fl of files.slice(0, 8)) {
          const ctx = DayLogger.hunkContexts(await this.runGit(repo, ["diff", "-U0", "HEAD", "--", fl.path]));
          out.push(`  [${hhmm(new Date(fl.at))}] ${fl.path}` + (ctx.length ? " — in: " + ctx.join("; ") : ""));
        }
        if (files.length > 8) out.push(`  …and ${files.length - 8} more`);
      }
      const latest = Math.max(files[0]?.at ?? dayStart, lastCommit);
      return { latest, text: out.join("\n") };
    });
    return blocks.filter((b): b is { latest: number; text: string } => b !== null)
      .sort((a, b) => b.latest - a.latest).map(b => b.text).join("\n");
  }

  private async aggregateGit(date: Date): Promise<string> {
    const repoDirs = await this.findRepos();
    if (repoDirs.length === 0) return "";
    const day = dayStamp(date);
    // One block per repo, filled concurrently: serially, ~30 repos of git
    // calls took ~12s, which a WhatsApp reply was waiting on.
    const blocks = await mapLimit(repoDirs, 6, async repo => {
      const lines: string[] = [];
      const commits = await this.runGit(repo, ["log", `--since=${day} 00:00:00`, `--until=${day} 23:59:59`,
        "--shortstat", "--pretty=format:%h %s"]);
      // Uncommitted work: tracked changes (working tree vs HEAD) + untracked files.
      // Captures in-flight features the user hasn't pushed/committed yet.
      const status = await this.runGit(repo, ["status", "--short"]);
      // Idle repo: stop at two git calls rather than five.
      if (!commits && !status) return lines;
      const uncommitted = await this.runGit(repo, ["diff", "--shortstat", "HEAD"]);
      const branch = await this.runGit(repo, ["branch", "--show-current"]);
      // Recent commit messages give the LLM context on what feature line is currently active.
      const recent = await this.runGit(repo, ["log", "-5", "--pretty=format:%h %s"]);
      lines.push(`### ${path.basename(repo)}`);
      if (branch) lines.push(`On branch: ${branch}`);
      if (commits) { lines.push("Committed today:"); lines.push(commits); }
      if (uncommitted || status) {
        lines.push("Uncommitted right now:");
        if (uncommitted) lines.push(uncommitted);
        if (status) lines.push(status);
      }
      if (recent) {
        lines.push("Recent commits (for context, may be older than today):");
        lines.push(recent);
      }
      return lines;
    });
    return blocks.flat().join("\n");
  }

  // MARK: - Claude Code session prompts

  private async aggregateClaudeSessions(date: Date): Promise<string> {
    const projectsDir = path.join(HOME, ".claude", "projects");
    let projects: fs.Dirent[];
    try { projects = await fs.promises.readdir(projectsDir, { withFileTypes: true }); } catch { return ""; }
    const dayStart = new Date(date.getFullYear(), date.getMonth(), date.getDate()).getTime();
    const dayEnd = new Date(date.getFullYear(), date.getMonth(), date.getDate() + 1).getTime();

    const prompts: { ts: number; project: string; text: string }[] = [];
    for (const proj of projects) {
      if (!proj.isDirectory()) continue;
      const projectName = humanizeClaudeProjectDir(proj.name);
      // Nikxel's own agent runs (chat replies, summaries) from before they
      // stopped being saved -- prompts Nikxel wrote, not the user.
      if (proj.name.includes("nikxel-momworkspace")) continue;
      const projDir = path.join(projectsDir, proj.name);
      let sessions: string[];
      try { sessions = await fs.promises.readdir(projDir); } catch { continue; }
      for (const s of sessions) {
        if (path.extname(s) !== ".jsonl") continue;
        const file = path.join(projDir, s);
        try { if ((await fs.promises.stat(file)).mtimeMs < dayStart) continue; } catch { continue; }
        let content: string;
        try { content = await fs.promises.readFile(file, "utf8"); } catch { continue; }
        for (const line of content.split("\n")) {
          // Cheap prefilter: most bytes are assistant and tool lines,
          // and JSON-parsing them all took ~10s on a busy day.
          if (!line.includes("\"type\":\"user\"")) continue;
          let obj: any;
          try { obj = JSON.parse(line); } catch { continue; }
          if (obj?.type !== "user" || obj.isMeta === true) continue;
          const raw = obj.message?.content;
          if (typeof raw !== "string") continue;
          // Filter slash commands, system reminders, and tool-result chunks.
          const trimmed = raw.trim();
          if (trimmed.startsWith("<command-name>") || trimmed.startsWith("<local-command-")
            || trimmed.startsWith("<system-reminder>") || trimmed === "") continue;
          const ts = typeof obj.timestamp === "string" ? Date.parse(obj.timestamp) : NaN;
          if (!Number.isFinite(ts) || ts < dayStart || ts >= dayEnd) continue;
          prompts.push({ ts, project: projectName, text: trimmed });
        }
        // Let the event loop breathe between session files.
        await new Promise<void>(r => setImmediate(r));
      }
    }

    if (prompts.length === 0) return "";
    prompts.sort((a, b) => a.ts - b.ts);
    // Cap each prompt to 300 chars so a single long paste doesn't blow the LLM context.
    // Cap total to 80 prompts so a heavy session day still fits.
    return prompts.slice(-80).map(p => {
      const oneLine = truncate(p.text, 300).replace(/\r?\n/g, " ");
      return `- [${hhmm(new Date(p.ts))}] (${p.project}) ${oneLine}`;
    }).join("\n");
  }

  // MARK: - Opencode session prompts

  /// Where opencode keeps its database. It uses xdg-basedir, which on Windows
  /// too resolves to ~/.local/share unless XDG_DATA_HOME is set; the AppData
  /// folders are checked in case a build ever follows Windows conventions.
  static opencodeDbCandidates(): string[] {
    const c: string[] = [];
    if (process.env.XDG_DATA_HOME) c.push(path.join(process.env.XDG_DATA_HOME, "opencode", "opencode.db"));
    c.push(path.join(HOME, ".local", "share", "opencode", "opencode.db"));
    if (isWin) {
      const local = process.env.LOCALAPPDATA ?? path.join(HOME, "AppData", "Local");
      const roaming = process.env.APPDATA ?? path.join(HOME, "AppData", "Roaming");
      c.push(path.join(local, "opencode", "opencode.db"), path.join(roaming, "opencode", "opencode.db"));
    }
    return c;
  }

  private async aggregateOpencodeSessions(date: Date): Promise<string> {
    const db = DayLogger.opencodeDbCandidates().find(p => fs.existsSync(p));
    if (!db) return "";
    // Untouched since before that day (db and its WAL): nothing to find,
    // and a cold query over a ~1 GB db costs seconds.
    const dayStart = new Date(date.getFullYear(), date.getMonth(), date.getDate()).getTime();
    const touched = Math.max(...[db, db + "-wal"].map(p => { try { return fs.statSync(p).mtimeMs; } catch { return 0; } }));
    if (touched > 0 && touched < dayStart) return "";
    const rows = await queryOpencode(db, dayStamp(date));
    // Cap each prompt to 300 chars, return time + text + session id (so the LLM can group by session).
    return rows.map(r => `- [${r.hm}] (ses ${r.sid}) ${String(r.text).replace(/\r?\n/g, " ")}`).join("\n");
  }

  // MARK: - WhatsApp

  private aggregateWhatsAppChats(date: Date): string {
    const lines: string[] = [], seen = new Set<string>();
    for (const e of safeReadLog("chats", date)) {
      if (typeof e?.t !== "number" || typeof e.name !== "string" || typeof e.preview !== "string") continue;
      // A preview that flips back is the same message: say it once.
      const key = e.name + "\0" + e.preview;
      if (seen.has(key)) continue;
      seen.add(key);
      lines.push(`- [${hhmm(new Date(e.t * 1000))}] ${e.name}: ${e.preview.replace(/\n/g, " ")}`);
    }
    return lines.join("\n");
  }

  private aggregateWhatsAppCalls(date: Date): string {
    const lines: string[] = [];
    for (const e of safeReadLog("calls", date)) {
      if (typeof e?.t !== "number" || typeof e.name !== "string") continue;
      const info = typeof e.info === "string" ? e.info : "";
      const waTime = typeof e.timeText === "string" ? e.timeText : "";
      lines.push(`- ${e.name} — ${info}${waTime ? ` (${waTime})` : ""} [seen ${hhmm(new Date(e.t * 1000))}]`);
    }
    return lines.join("\n");
  }

  private gitMissingLogged = false;

  private async runGit(repo: string, args: string[]): Promise<string> {
    const bin = which("git");
    if (!bin) {
      if (!this.gitMissingLogged) { this.gitMissingLogged = true; cblog("DayLogger: git not found — install Git for Windows for the Git sections"); }
      return "";
    }
    const r = await run(bin, ["-C", repo, ...args], { timeoutMs: 30_000, env: { GIT_TERMINAL_PROMPT: "0", GCM_INTERACTIVE: "never" } });
    return r.code === 0 ? r.stdout.trim() : "";
  }

  private summaryPrompt(report: string, date: Date): string {
    const day = dayStamp(date);
    return `You are generating an end-of-day journal entry for the user, based on raw activity data captured throughout the day:
- Foreground app + window-title samples (every 15s) — shows what was on screen.
- Meetings they recorded today (with the MOM summaries).
- Git activity per project: commits today, uncommitted changes, current branch, recent commit history.
- Claude Code session prompts: the user's actual messages to Claude today, timestamped, with project name.
- Opencode session prompts: the user's actual messages to opencode today, timestamped.
- WhatsApp chats: periodic preview-text snapshots of each chat through the day (name + a short text excerpt), NOT full conversations.
- WhatsApp calls: call-log entries (caller, missed/incoming/outgoing, WhatsApp's own time label) — no call content/audio is available unless that call happened to be recorded as a meeting (in which case it shows up under Meetings too).

The session prompts are the most informative signal: they tell you LITERALLY what bug or feature the user was working on, in their own words. Use them as the spine of the narrative.

For WhatsApp chats specifically: look for signs a task/ask was assigned to the user in a message ("can you...", "please...", "need you to...", a deadline, a request) and note who sent it and what it was. Only flag it as "done" if there's later evidence in the same data (a reply, a relevant commit, a later message) that it was acted on — otherwise mark it open/unclear. Don't force a task interpretation onto ordinary chit-chat.

${Settings.languageInstruction}

Write a friendly, personal, specific narrative. Not generic ("worked on coding") but specific ("fixed the typing-animation lag bug in Nikxel — diagnosed it as a missing CGEventTap re-enable, then added day-of-week logging").

Date: ${day}

Output this exact Markdown structure:

# ${day} — Day in review

## Summary
2-4 sentences capturing the overall shape of the day: which projects dominated, what specific features/bugs you worked on (use the session-prompt data!), what kind of day it was.

## What you worked on
- Per-feature/bug bullets. Anchor each one to a real ask from the session prompts when possible: "Fixed the typing-linger bug (asked at ~3pm, shipped commit abc123, ~50 line diff)." Group related prompts into one bullet — don't list every prompt verbatim.
- Note both shipped work (commits) and in-flight work (uncommitted diff).

## Meetings
- One bullet per meeting: time, who/what (use the MOM summary if present), key outcome if obvious.
- If none, write "- None today."

## WhatsApp
- Calls: one bullet per call (who, missed/incoming/outgoing, when). If none, write "- No calls today."
- Tasks assigned in chats: one bullet per task you can identify — "<Who> asked you to <what> (~<time>) — <done/open/unclear>". If none, write "- No tasks assigned today."
- Anything else notable from chats worth a quick mention. If nothing, write "- Nothing else notable."

## Browsing & Reading
- Time in browser/reading apps, summarized ("~45 min in Chrome — mostly docs"). Don't list every URL.

## Other
- Anything else worth flagging: long focus blocks, fragmented mornings, unusual late-night activity, repeated context switches, etc.

Rules:
- Never invent activity not in the data. Inferring is OK ("session prompts mention 'typing lag' and you committed to StateMachine.swift, so you were fixing the typing bug") — flag uncertain inferences.
- When session prompts and git activity disagree, prefer what the session prompts say the user was trying to do.
- Output ONLY the Markdown — no preamble, no closing remarks.

---
RAW ACTIVITY DATA:
${report}
`;
  }
}

function extractSection(markdown: string, heading: string): string | null {
  let capturing = false;
  const out: string[] = [];
  for (const line of markdown.split("\n")) {
    const t = line.trim();
    if (t.startsWith("## ")) {
      if (capturing) break;
      if (t.slice(3).trim() === heading) { capturing = true; continue; }
    } else if (capturing) {
      out.push(line);
    }
  }
  const joined = out.join("\n").trim();
  return joined === "" ? null : joined;
}

/// Claude Code encodes cwds like "C--Users-nikhil-Desktop-projects-nikxel"
/// (or "-Users-nikhildhanda-..." on a Mac). The last segment is the human
/// project name.
function humanizeClaudeProjectDir(raw: string): string {
  const parts = raw.split("-").filter(p => p !== "");
  return parts[parts.length - 1] ?? raw;
}

/// The WhatsApp logger is another module's; a log it can't read must not
/// take the day report down with it.
function safeReadLog(file: "chats" | "calls", day: Date): any[] {
  try {
    const r = WhatsAppActivityLogger.readLog(file, day);
    return Array.isArray(r) ? r : [];
  } catch {
    return [];
  }
}

/// Queries opencode's SQLite database read-only with node:sqlite, in a worker
/// thread: the query is synchronous and a cold one over a ~1 GB database
/// takes seconds, which the main process can't spend frozen.
function queryOpencode(db: string, day: string): Promise<{ hm: string; sid: string; text: string }[]> {
  const code = `
const { parentPort, workerData } = require("worker_threads");
let rows = [];
try {
  const { DatabaseSync } = require("node:sqlite");
  const db = new DatabaseSync(workerData.db, { readOnly: true });
  try {
    rows = db.prepare(\`
      SELECT strftime('%H:%M', m.time_created/1000, 'unixepoch', 'localtime') AS hm,
             substr(m.session_id, 1, 12) AS sid,
             substr(json_extract(p.data, '$.text'), 1, 300) AS text
      FROM message m
      JOIN part p ON p.message_id = m.id
      WHERE json_extract(m.data, '$.role') = 'user'
        AND json_extract(p.data, '$.type') = 'text'
        AND date(m.time_created/1000, 'unixepoch', 'localtime') = ?
      ORDER BY m.time_created ASC
      LIMIT 80\`).all(workerData.day);
  } finally { db.close(); }
  parentPort.postMessage({ rows });
} catch (e) {
  parentPort.postMessage({ rows: [], error: String(e && e.message || e) });
}
`;
  return new Promise(resolve => {
    let done = false;
    const finish = (rows: { hm: string; sid: string; text: string }[]) => { if (!done) { done = true; resolve(rows); } };
    let w: Worker;
    try {
      w = new Worker(code, { eval: true, workerData: { db, day } });
    } catch (e) {
      diag("DayLogger", `opencode query worker failed to start: ${e}`);
      finish([]);
      return;
    }
    const timer = setTimeout(() => { w.terminate().catch(() => {}); finish([]); }, 60_000);
    w.on("message", (m: { rows: any[]; error?: string }) => {
      clearTimeout(timer);
      if (m.error) diag("DayLogger", `opencode query failed: ${m.error}`);
      finish((m.rows ?? []).filter(r => r && r.text != null)
        .map(r => ({ hm: String(r.hm ?? "?"), sid: String(r.sid ?? ""), text: String(r.text) })));
      w.terminate().catch(() => {});
    });
    w.on("error", e => { clearTimeout(timer); diag("DayLogger", `opencode query worker error: ${e}`); finish([]); });
    w.on("exit", () => { clearTimeout(timer); finish([]); });
  });
}

