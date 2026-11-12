import * as fs from "fs";
import * as path from "path";
import { HOME, appendLine, dayStamp, ensureDir } from "../core/paths";
import { ChromeWhatsApp } from "./chromeWhatsApp";

/// Where the day's WhatsApp activity goes. The Mac used
/// ~/Library/Application Support/Nikxel/whatsapp; Windows' equivalent is
/// %APPDATA%\Nikxel\whatsapp.
function logDirectory(): string {
  const appData = process.env.APPDATA ?? path.join(HOME, "AppData", "Roaming");
  return path.join(appData, "Nikxel", "whatsapp");
}

function fileURL(logDir: string, file: string, date: Date): string {
  return path.join(logDir, `${file}-${dayStamp(date)}.jsonl`);
}

/// Runs all day (independent of meeting state) building a running record of
/// WhatsApp activity — chat previews and call-log entries — so `DayLogger`
/// can fold "what happened on WhatsApp today" (incl. tasks assigned in chats,
/// and any calls) into the end-of-day summary.
///
/// Reuses the same WhatsApp window/CDP bridge as `ChatbotEngine`
/// (`ChromeWhatsApp`), just polled on a slower, always-on cadence. WhatsApp
/// Web exposes no call audio/transcript — only call-log metadata (caller,
/// missed/incoming/outgoing, time). If a WhatsApp call is actually recorded
/// via Nikxel's normal meeting recorder, its transcript/MOM is picked up
/// separately through the regular meetings pipeline.
export class WhatsAppActivityLogger {
  static readonly shared = new WhatsAppActivityLogger();

  private chatTimer: NodeJS.Timeout | null = null;
  private callTimer: NodeJS.Timeout | null = null;
  private readonly chatInterval = 120_000;   // 2 min — cheap, no tab switch
  private readonly callInterval = 600_000;   // 10 min — switches tabs, so less often

  private readonly logDir: string;
  // One poll at a time, like the Mac's serial queue.
  private busy: Promise<void> = Promise.resolve();

  // In-memory dedupe so we only append NEW info to the day's log, same
  // delta-logging shape as DayLogger's app-usage sampler.
  private lastPreview = new Map<string, string>();
  private seenCallKeys = new Set<string>();

  constructor() {
    this.logDir = logDirectory();
    ensureDir(this.logDir);
  }

  start(): void {
    this.stop();
    this.pollChats();
    this.chatTimer = setInterval(() => this.pollChats(), this.chatInterval);
    this.pollCalls();
    this.callTimer = setInterval(() => this.pollCalls(), this.callInterval);
  }

  stop(): void {
    if (this.chatTimer) clearInterval(this.chatTimer);
    if (this.callTimer) clearInterval(this.callTimer);
    this.chatTimer = null;
    this.callTimer = null;
  }

  // MARK: - Polling

  private enqueue(job: () => Promise<void>): void {
    this.busy = this.busy.then(job).catch(() => {});
  }

  private pollChats(): void {
    this.enqueue(async () => {
      const chats = await ChromeWhatsApp.allChatsPreview();
      if (chats.length === 0) return;
      for (const chat of chats) {
        if (this.lastPreview.get(chat.name) === chat.preview) continue;
        this.lastPreview.set(chat.name, chat.preview);
        this.appendJSONL("chats", { t: Date.now() / 1000, name: chat.name, preview: chat.preview });
      }
    });
  }

  private pollCalls(): void {
    this.enqueue(async () => {
      try {
        const calls = await ChromeWhatsApp.callLog();
        for (const call of calls) {
          const key = `${call.name}|${call.info}|${call.timeText}`;
          if (this.seenCallKeys.has(key)) continue;
          this.seenCallKeys.add(key);
          this.appendJSONL("calls", { t: Date.now() / 1000, name: call.name, info: call.info, timeText: call.timeText });
        }
      } finally {
        // Always restore the Chats tab afterward — ChatbotEngine's unread
        // polling assumes the chat list, not the call log, is on screen.
        await ChromeWhatsApp.openChatsTab();
      }
    });
  }

  // MARK: - Persistence

  private appendJSONL(file: string, entry: Record<string, unknown>): void {
    let line: string;
    try { line = JSON.stringify(entry); } catch { return; }
    appendLine(fileURL(this.logDir, file, new Date()), line);
  }

  /// Read back today's (or any day's) raw entries for `DayLogger` to fold
  /// into the EOD summary prompt.
  static readLog(file: "chats" | "calls", day: Date): any[] {
    let content: string;
    try { content = fs.readFileSync(fileURL(logDirectory(), file, day), "utf8"); } catch { return []; }
    const out: any[] = [];
    for (const line of content.split("\n")) {
      if (!line.trim()) continue;
      try {
        const obj = JSON.parse(line);
        if (obj && typeof obj === "object" && !Array.isArray(obj)) out.push(obj);
      } catch { /* a torn last line from a crash */ }
    }
    return out;
  }
}
