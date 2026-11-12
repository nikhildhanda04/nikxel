import * as crypto from "crypto";
import * as fs from "fs";
import * as path from "path";
import { nikxelPath, ensureDir, writeAtomic } from "../core/paths";
import { Settings } from "../core/settings";
import { cblog } from "../core/diag";
import { ui } from "../core/ui";
import { openFile } from "../core/open";
import { GoogleAuth } from "./googleAuth";
import { rememberOwnTask } from "./reminderWatcher";

/// Turns a finished meeting note into Google Tasks and follow-up Google
/// Calendar events (with a Meet link).
///
/// It reads the Markdown the agent already wrote rather than asking the model
/// again: `## Action Items` and `## Follow-Up Meetings` are emitted in a fixed,
/// parseable line format for exactly this reason. A second LLM pass would cost
/// another minute and could invent items the note doesn't contain.
///
/// Nothing is ever pushed without the user saying yes to a dialog that lists
/// every item first -- this writes into somebody's real todo list and calendar.

// MARK: - Parsed shapes

export class ActionItem {
  constructor(public title: string, public owner: string, public due: Date | null) {}

  /// Owner with the "(Me)" marker removed. The Speakers section labels
  /// the user as "Jake (Me)", so that -- not a bare first name -- is what
  /// actually lands in the Owner field, and comparing it raw against the
  /// user's name never matched.
  get normalizedOwner(): string {
    return this.owner.replace(/\(Me\)/gi, "").trim();
  }

  /// True when this is the user's own task, or nobody's.
  isMine(ownName: string): boolean {
    const o = this.normalizedOwner.toLowerCase();
    return o === ""
      || o === ownName.toLowerCase()
      || o === "me"
      || o === "unassigned";
  }

  /// Other people's tasks get their name up front, so a glance at the
  /// Google Tasks list shows whose it is -- Tasks has no assignee field.
  taskTitle(ownName: string): string {
    return this.isMine(ownName) ? this.title : `[${this.normalizedOwner}] ${this.title}`;
  }
}

export interface FollowUp {
  title: string;
  start: Date;
  durationMin: number;
  with: string;
}

/// Why a chat task couldn't be filed, when it's something the user can
/// actually fix.
///  - needsReconnect: connected before Nikxel could write; one click re-grants.
///  - apiDisabled: the Tasks API isn't switched on for the OAuth project.
///    Nothing in Nikxel can do this -- it's a toggle in the Cloud console.
export type ChatTaskBlock =
  | { kind: "needsReconnect" }
  | { kind: "apiDisabled"; url: string | null }
  | { kind: "other"; reason: string };

const TASKS_SCOPE = "https://www.googleapis.com/auth/tasks";
const EVENTS_SCOPE = "https://www.googleapis.com/auth/calendar.events";
const TASKS_URL = "https://tasks.googleapis.com/tasks/v1/lists/@default/tasks";
const EVENTS_URL = "https://www.googleapis.com/calendar/v3/calendars/primary/events";

const MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
const pad = (n: number) => String(n).padStart(2, "0");

function lines(s: string): string[] { return s.split(/\r\n|\r|\n/); }

/// Offset of `tz` from UTC at the instant `utcMs`, in ms.
function tzOffsetMs(utcMs: number, tz: string): number {
  const parts = new Intl.DateTimeFormat("en-US", {
    timeZone: tz, hourCycle: "h23",
    year: "numeric", month: "2-digit", day: "2-digit",
    hour: "2-digit", minute: "2-digit", second: "2-digit",
  }).formatToParts(new Date(utcMs));
  const get = (t: string) => Number(parts.find(p => p.type === t)?.value ?? 0);
  const asUTC = Date.UTC(get("year"), get("month") - 1, get("day"), get("hour"), get("minute"), get("second"));
  return asUTC - Math.floor(utcMs / 1000) * 1000;
}

/// The instant a wall-clock time names in `tz` (an IANA zone; local time
/// when omitted), or null for an impossible date like 2026-02-30 -- the
/// Swift DateFormatter isn't lenient either.
function wallClock(y: number, mo: number, d: number, h: number, mi: number, tz?: string): Date | null {
  const probe = new Date(Date.UTC(y, mo - 1, d, h, mi));
  if (probe.getUTCFullYear() !== y || probe.getUTCMonth() !== mo - 1 || probe.getUTCDate() !== d
      || probe.getUTCHours() !== h || probe.getUTCMinutes() !== mi) return null;
  if (!tz) return new Date(y, mo - 1, d, h, mi);
  const guess = probe.getTime();
  const off1 = tzOffsetMs(guess, tz);
  let t = guess - off1;
  const off2 = tzOffsetMs(t, tz);
  if (off2 !== off1) t = guess - off2;
  return new Date(t);
}

/// "2026-11-12T15:30:00+05:30" in local time, like ISO8601DateFormatter
/// with .withInternetDateTime and timeZone = .current.
function isoLocal(d: Date): string {
  const offMin = -d.getTimezoneOffset();
  const zone = offMin === 0 ? "Z"
    : `${offMin > 0 ? "+" : "-"}${pad(Math.floor(Math.abs(offMin) / 60))}:${pad(Math.abs(offMin) % 60)}`;
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}T${pad(d.getHours())}:${pad(d.getMinutes())}:${pad(d.getSeconds())}${zone}`;
}

function localTimeZoneId(): string {
  return Intl.DateTimeFormat().resolvedOptions().timeZone || "UTC";
}

function plural(n: number, word: string): string {
  return `${n} ${word}${n === 1 ? "" : "s"}`;
}

export abstract class GoogleSync {

  // MARK: - Parsing

  /// `- [ ] **Task** — Owner: Priya — Due: 2026-11-12`
  ///
  /// Fields are found from the right so an em dash inside the task text
  /// ("Ship the API — not the docs — by Friday") doesn't split the title.
  /// `tz` is an IANA zone name; local time when omitted.
  static parseActionItems(markdown: string, tz?: string): ActionItem[] {
    const items: ActionItem[] = [];
    for (const raw of lines(GoogleSync.section(markdown, "Action Items"))) {
      const line = raw.trim();
      if (!(line.startsWith("- [ ]") || line.startsWith("- [x]"))) continue;
      let body = line.slice(5).trim();

      let due: Date | null = null;
      let r = body.lastIndexOf("— Due:");
      if (r >= 0) {
        due = GoogleSync.parseDay(body.slice(r + "— Due:".length), tz);
        body = body.slice(0, r);
      }
      let owner = "";
      r = body.lastIndexOf("— Owner:");
      if (r >= 0) {
        owner = body.slice(r + "— Owner:".length).trim();
        body = body.slice(0, r);
      }
      if (owner.toLowerCase() === "unassigned") owner = "";

      const title = cleanInline(body);
      if (!title) continue;
      // The prompt's own "no tasks" placeholder, not a task.
      if (title.toLowerCase().startsWith("none")) continue;
      items.push(new ActionItem(title, owner, due));
    }
    return items;
  }

  /// `- **Design review** — When: 2026-11-12 15:30 — Duration: 45 min — With: Priya, Rohan`
  ///
  /// Only lines with a concrete date AND time become events. "Not specified"
  /// is left alone on purpose: inventing a slot in someone's calendar is
  /// worse than not creating the event at all.
  static parseFollowUps(markdown: string, tz?: string): FollowUp[] {
    const ups: FollowUp[] = [];
    for (const raw of lines(GoogleSync.section(markdown, "Follow-Up Meetings"))) {
      const line = raw.trim();
      if (!line.startsWith("- ")) continue;
      let body = line.slice(2).trim();

      let withWhom = "";
      let r = body.lastIndexOf("— With:");
      if (r >= 0) {
        withWhom = body.slice(r + "— With:".length).trim();
        body = body.slice(0, r);
      }
      let duration = 30;
      r = body.lastIndexOf("— Duration:");
      if (r >= 0) {
        const digits = body.slice(r + "— Duration:".length).replace(/\D/g, "");
        const n = digits ? Number(digits) : NaN;
        if (Number.isInteger(n) && n > 0 && n <= 8 * 60) duration = n;
        body = body.slice(0, r);
      }
      let start: Date | null = null;
      r = body.lastIndexOf("— When:");
      if (r >= 0) {
        start = GoogleSync.parseMoment(body.slice(r + "— When:".length), tz);
        body = body.slice(0, r);
      }

      const title = cleanInline(body);
      if (!title || title.toLowerCase().startsWith("none") || !start) continue;
      if (withWhom.toLowerCase() === "not specified") withWhom = "";
      ups.push({ title, start, durationMin: duration, with: withWhom });
    }
    return ups;
  }

  /// Everything under `## <heading>` up to the next `##`. Returns "" when the
  /// note has no such section -- an older note, or a user whose summary style
  /// told the model to drop it.
  static section(markdown: string, heading: string): string {
    const out: string[] = [];
    let inside = false;
    for (const line of lines(markdown)) {
      const t = line.trim();
      if (t.startsWith("## ")) {
        const name = t.slice(3).trim();
        inside = name.toLowerCase() === heading.toLowerCase();
        continue;
      }
      // A deeper heading (### inside Agent Prompts) stays part of its section.
      if (inside) out.push(line);
    }
    return out.join("\n");
  }

  /// "2026-11-12" -> that day. Anything else (prose like "next Friday", or
  /// "Not specified") -> null, and the task is created without a due date.
  static parseDay(s: string, tz?: string): Date | null {
    const t = s.trim().replace(/\*/g, "");
    const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(t.slice(0, 10));
    if (!m) return null;
    return wallClock(Number(m[1]), Number(m[2]), Number(m[3]), 0, 0, tz);
  }

  /// "2026-11-12 15:30" or "2026-11-12T15:30". A date with no time is not a
  /// moment -- a follow-up needs both, so this returns null rather than
  /// defaulting to midnight.
  static parseMoment(s: string, tz?: string): Date | null {
    const t = s.trim().replace(/\*/g, "").replace(/T/g, " ");
    const m = /^(\d{4})-(\d{2})-(\d{2}) (\d{2}):(\d{2})$/.exec(t.slice(0, 16));
    if (!m) return null;
    return wallClock(Number(m[1]), Number(m[2]), Number(m[3]), Number(m[4]), Number(m[5]), tz);
  }

  // MARK: - Already-synced markers

  private static get syncedDir(): string {
    return ensureDir(nikxelPath("synced"));
  }

  /// Keyed by the note's filename stem, so regenerating or re-opening a
  /// summary can't quietly duplicate everything in the user's todo list.
  static isSynced(notePath: string): boolean {
    return fs.existsSync(GoogleSync.markerPath(notePath));
  }

  private static markerPath(notePath: string): string {
    const stem = path.basename(notePath, path.extname(notePath));
    return path.join(GoogleSync.syncedDir, stem + ".json");
  }

  private static markSynced(notePath: string, tasks: number, events: number): void {
    const payload = { tasks, events, at: Date.now() / 1000 };
    try { writeAtomic(GoogleSync.markerPath(notePath), JSON.stringify(payload)); } catch { /* best effort */ }
  }

  // MARK: - Entry point

  /// Reads `notePath`, and if it contains anything actionable, asks the user
  /// whether to push it to Google.
  static async offer(notePath: string): Promise<void> {
    if (!Settings.googleSyncEnabled) return;
    if (GoogleSync.isSynced(notePath)) return;
    // saveOutput hands back the .pdf/.docx when that's the chosen note
    // format. The Markdown is always written alongside it, and it is the
    // only one of the three this can parse.
    const ext = path.extname(notePath);
    const mdPath = ext.toLowerCase() === ".md" ? notePath : notePath.slice(0, notePath.length - ext.length) + ".md";
    let md: string;
    try { md = await fs.promises.readFile(mdPath, "utf8"); } catch { return; }

    const tasks = GoogleSync.parseActionItems(md);
    const events = GoogleSync.parseFollowUps(md);
    if (tasks.length === 0 && events.length === 0) return;

    // Don't nag someone who has never connected Google -- there is nothing
    // they can usefully do with the dialog.
    if (!GoogleAuth.shared.isAuthorized) return;

    const missing = [TASKS_SCOPE, EVENTS_SCOPE].filter(s => !GoogleAuth.shared.hasScope(s));
    if (missing.length > 0) {
      ui.ask({
        icon: "🔑", title: "Reconnect Google to send these to Tasks", lines: [
          `This summary has ${plural(tasks.length, "task")}${events.length === 0 ? "" : ` and ${plural(events.length, "follow-up meeting")}`}.`,
          "Google was connected before Nikxel could write to it. One click re-grants.",
        ], buttons: [
          { title: "Reconnect", action: () => GoogleAuth.shared.reauthenticate() },
          { title: "Not now", action: () => {} },
        ],
      });
      return;
    }

    // The card shows 5 lines; the full list is in the note ("Open note").
    const ownName = Settings.userName;
    let cardLines: string[] = events.map(e => `📅 ${e.title} — ${shortMoment(e.start)}, ${e.durationMin} min`);
    for (const t of tasks) {
      const when = t.due ? ` (due ${shortDay(t.due)})` : "";
      cardLines.push(`${t.taskTitle(ownName)}${when}`);
    }
    const total = cardLines.length;
    if (total > 5) cardLines = [...cardLines.slice(0, 4), `…and ${total - 4} more`];

    ui.ask({
      icon: "✅", title: "Send this meeting's tasks to Google?", lines: cardLines, bulleted: true,
      buttons: [
        {
          title: events.length === 0 ? `Add ${plural(tasks.length, "task")}` : "Add to Google",
          action: () => void GoogleSync.push(tasks, events, mdPath),
        },
        { title: "Not now", action: () => {} },
        { title: "Open note", action: () => void openFile(notePath) },   // the format they chose, not the .md
      ],
    });
  }

  // MARK: - Writing to Google

  private static async push(tasks: ActionItem[], events: FollowUp[], notePath: string): Promise<void> {
    let token: string;
    try { token = await GoogleAuth.shared.getAccessToken(); } catch {
      GoogleAuth.shared.showAlert("Couldn't refresh your Google login. Try Connect Google Account from the menu.");
      return;
    }
    const ownName = Settings.userName;
    let created = 0;
    const failures: string[] = [];
    const meetLinks: string[] = [];

    await Promise.all([
      ...tasks.map(async t => {
        const err = await GoogleSync.createTask(t, ownName, notePath, token);
        if (err) failures.push(`task “${t.title}”: ${err}`); else created += 1;
      }),
      ...events.map(async e => {
        const { link, err } = await GoogleSync.createEvent(e, notePath, token);
        if (err) failures.push(`meeting “${e.title}”: ${err}`);
        else { created += 1; if (link) meetLinks.push(`${e.title}: ${link}`); }
      }),
    ]);

    // Mark synced on partial success too: re-running would duplicate
    // everything that did land, which is worse than leaving the few
    // failures to be added by hand.
    if (created > 0) GoogleSync.markSynced(notePath, tasks.length, events.length);
    let msg = created > 0 ? `Added ${plural(created, "item")} to Google.` : "Nothing was added.";
    if (meetLinks.length > 0) msg += "\n\nMeet links:\n" + meetLinks.join("\n");
    if (failures.length > 0) msg += "\n\nFailed:\n" + failures.slice(0, 5).join("\n");
    GoogleAuth.shared.showAlert(msg);
  }

  // MARK: - Tasks out of WhatsApp chats

  /// Fired at most once per launch when a chat task is blocked. Wired to the
  /// avatar card in main.ts -- without it the user's tasks vanish into a log
  /// file they have no reason to open.
  static onChatTaskBlocked: ((b: ChatTaskBlock) => void) | null = null;
  private static warnedTaskBlock = false;

  private static reportBlocked(b: ChatTaskBlock): void {
    if (GoogleSync.warnedTaskBlock) return;
    GoogleSync.warnedTaskBlock = true;
    setImmediate(() => GoogleSync.onChatTaskBlocked?.(b));
  }

  /// Google answers a switched-off API with a 403 naming the console page
  /// that turns it on. Lift that URL so the card can open it directly.
  static consoleURL(message: string): string | null {
    const i = message.indexOf("https://console.developers.google.com/");
    if (i < 0) return null;
    const tail = message.slice(i);
    const cut = tail.search(/[ \n]/);
    return cut < 0 ? tail : tail.slice(0, cut);
  }

  /// Whether an API error means "this API is not switched on for the project".
  static isAPIDisabled(message: string): boolean {
    const m = message.toLowerCase();
    return m.includes("has not been used in project") || m.includes("is disabled");
  }

  /// File one task that came out of a chat message. Resolves to the error,
  /// or null when it was filed. Never rejects.
  ///
  /// Silent, unlike `offer`: a modal per WhatsApp message would be worse than
  /// the problem it solves, and this only ever writes to the user's own task
  /// list. No-ops -- with a log line, not an alert -- when Google isn't
  /// connected or was connected before Nikxel could write, so the bot never
  /// nags about a feature the user hasn't set up.
  ///
  /// ponytail: title only, no due date. Any "by Friday" the contact wrote
  /// stays inside the title, which Google Tasks shows in full. Parsing a date
  /// out of chat prose is a bigger job than the value, and a task filed under
  /// the wrong Friday is worse than one with no date at all.
  static async createChatTask(title: string, contact: string): Promise<string | null> {
    if (!Settings.waChatTasks) return "chat tasks off";
    const clean = title.trim();
    if (!clean) return "empty title";
    if (!GoogleAuth.shared.isAuthorized) {
      cblog(`GoogleSync: chat task '${clean}' not filed — no Google account connected`);
      return "not connected";
    }
    if (!GoogleAuth.shared.hasScope(TASKS_SCOPE)) {
      cblog(`GoogleSync: chat task '${clean}' not filed — reconnect Google to grant Tasks access`);
      GoogleSync.reportBlocked({ kind: "needsReconnect" });
      return "missing scope";
    }
    let token: string;
    try { token = await GoogleAuth.shared.getAccessToken(); } catch {
      cblog(`GoogleSync: chat task '${clean}' not filed — couldn't refresh the Google login`);
      return "no token";
    }
    const { obj, err } = await GoogleSync.post(TASKS_URL, "POST",
      { title: clean, notes: `From a WhatsApp message from ${contact}.` }, token);
    if (err) {
      cblog(`GoogleSync: chat task '${clean}' failed — ${err}`);
      // Measured: a project that has never used Tasks answers 403
      // with exactly this, and every task after it would have
      // failed the same silent way.
      GoogleSync.reportBlocked(GoogleSync.isAPIDisabled(err)
        ? { kind: "apiDisabled", url: GoogleSync.consoleURL(err) }
        : { kind: "other", reason: err });
    } else {
      // Windows: the Tasks watcher must not bubble this back as a new reminder.
      if (typeof obj?.id === "string") rememberOwnTask(obj.id);
      cblog(`GoogleSync: filed chat task '${clean}' (from ${contact})`);
    }
    return err;
  }

  private static async createTask(item: ActionItem, ownName: string, notePath: string, token: string): Promise<string | null> {
    const body: Record<string, unknown> = { title: item.taskTitle(ownName) };
    let notes = `From ${path.basename(notePath)}`;
    if (!item.isMine(ownName)) notes = `Owner: ${item.normalizedOwner}\n` + notes;
    body.notes = notes;
    if (item.due) {
      // Google Tasks stores a date only; the time part is ignored but the
      // field still has to be full RFC3339. The day is the one the note
      // named, read in local time -- formatting local midnight in UTC
      // would file it a day early anywhere east of Greenwich.
      const d = item.due;
      body.due = `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}T00:00:00Z`;
    }
    const { obj, err } = await GoogleSync.post(TASKS_URL, "POST", body, token);
    if (!err && typeof obj?.id === "string") rememberOwnTask(obj.id);
    return err;
  }

  private static async createEvent(e: FollowUp, notePath: string, token: string): Promise<{ link: string | null; err: string | null }> {
    let description = `Follow-up from ${path.basename(notePath)}.`;
    // Names only -- the transcript never contains email addresses, and
    // guessing one would invite a stranger to the user's meeting.
    if (e.with) description += `\n\nDiscussed with: ${e.with}. Invite them yourself — Nikxel only had their names.`;

    const body = {
      summary: e.title,
      description,
      start: GoogleSync.eventTime(e.start),
      end: GoogleSync.eventTime(new Date(e.start.getTime() + e.durationMin * 60_000)),
      conferenceData: {
        createRequest: {
          requestId: crypto.randomUUID().toUpperCase(),
          conferenceSolutionKey: { type: "hangoutsMeet" },
        },
      },
    };
    const { obj, err } = await GoogleSync.post(`${EVENTS_URL}?conferenceDataVersion=1`, "POST", body, token);
    return { link: typeof obj?.hangoutLink === "string" ? obj.hangoutLink : null, err };
  }

  // MARK: - Calls agreed in WhatsApp

  static get canScheduleMeets(): boolean {
    return GoogleAuth.shared.isAuthorized && GoogleAuth.shared.hasScope(EVENTS_SCOPE);
  }

  /// No Google account: a Jitsi room needs no account or API to create --
  /// the link is the room. Random name so it can't be guessed.
  /// ponytail: public meet.jit.si, whose first joiner signs in (Google,
  /// GitHub or Facebook) to open the room. Point it at a self-hosted or
  /// login-free Jitsi instance if that ever bites.
  static jitsiLink(): string {
    return "https://meet.jit.si/Nikxel-" + crypto.randomUUID().toUpperCase().replace(/-/g, "").slice(0, 16);
  }

  /// A 30-minute calendar event with a Meet link, for a call agreed with a
  /// WhatsApp contact. Resolves to the link and the event id (to move or
  /// delete it). Without Google -- or if Google fails -- the link is a Jitsi
  /// room and the id is null, so there is no event to move or delete.
  /// Never rejects.
  static async createChatMeet(contact: string, start: Date): Promise<{ link: string | null; eventId: string | null }> {
    if (!GoogleSync.canScheduleMeets) return { link: GoogleSync.jitsiLink(), eventId: null };
    let token: string;
    try { token = await GoogleAuth.shared.getAccessToken(); } catch {
      return { link: GoogleSync.jitsiLink(), eventId: null };
    }
    const { obj, err } = await GoogleSync.post(`${EVENTS_URL}?conferenceDataVersion=1`, "POST", {
      summary: `Call with ${contact}`,
      description: `Agreed over WhatsApp. Nikxel sends ${contact} the Meet link at the start time.`,
      start: GoogleSync.eventTime(start), end: GoogleSync.eventTime(new Date(start.getTime() + 30 * 60_000)),
      conferenceData: {
        createRequest: {
          requestId: crypto.randomUUID().toUpperCase(),
          conferenceSolutionKey: { type: "hangoutsMeet" },
        },
      },
    }, token);
    if (err) cblog(`GoogleSync: Meet for '${contact}' failed — ${err}; using Jitsi`);
    const link = typeof obj?.hangoutLink === "string" ? obj.hangoutLink : null;
    if (!link) return { link: GoogleSync.jitsiLink(), eventId: null };
    return { link, eventId: typeof obj?.id === "string" ? obj.id : null };
  }

  /// Same event, same link, new time. Never rejects.
  static async moveChatMeet(eventId: string, start: Date): Promise<void> {
    let token: string;
    try { token = await GoogleAuth.shared.getAccessToken(); } catch { return; }
    const { err } = await GoogleSync.post(`${EVENTS_URL}/${encodeURIComponent(eventId)}`, "PATCH",
      { start: GoogleSync.eventTime(start), end: GoogleSync.eventTime(new Date(start.getTime() + 30 * 60_000)) },
      token);
    if (err) cblog(`GoogleSync: moving Meet ${eventId} failed — ${err}`);
  }

  /// Never rejects.
  static async deleteChatMeet(eventId: string): Promise<void> {
    let token: string;
    try { token = await GoogleAuth.shared.getAccessToken(); } catch { return; }
    const { err } = await GoogleSync.post(`${EVENTS_URL}/${encodeURIComponent(eventId)}`, "DELETE", null, token);
    if (err) cblog(`GoogleSync: deleting Meet ${eventId} failed — ${err}`);
  }

  private static eventTime(d: Date): { dateTime: string; timeZone: string } {
    return { dateTime: isoLocal(d), timeZone: localTimeZoneId() };
  }

  /// One JSON request against a Google API. Resolves to the parsed body
  /// (also on an error status, when there is one) and the error message, or
  /// null on a 2xx. Never rejects.
  static async post(url: string, method: string, body: unknown, token: string): Promise<{ obj: any; err: string | null }> {
    let res: Response;
    try {
      res = await fetch(url, {
        method,
        headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
        body: body === null || body === undefined ? undefined : JSON.stringify(body),
      });
    } catch (e) {
      return { obj: null, err: (e as Error).message || "request failed" };
    }
    const text = await res.text().catch(() => "");
    let obj: any = null;
    try { obj = text ? JSON.parse(text) : null; } catch { obj = null; }
    if (obj !== null && typeof obj !== "object") obj = null;
    if (res.status === 401) GoogleAuth.shared.invalidateAccessToken();
    if (res.status < 200 || res.status >= 300) {
      const inner = obj?.error?.message;
      return { obj, err: typeof inner === "string" ? inner : `HTTP ${res.status}` };
    }
    return { obj, err: null };
  }
}

/// Strips bold/italic/code markers and surrounding punctuation left behind
/// after the trailing fields are sliced off.
function cleanInline(s: string): string {
  let t = s.trim();
  t = t.replace(/\*\*/g, "").replace(/`/g, "");
  while (t.length > 0 && ["—", "-", ",", ":"].includes(t[t.length - 1])) {
    t = t.slice(0, -1).trim();
  }
  return t.trim();
}

function shortDay(d: Date): string {
  return `${d.getDate()} ${MONTHS[d.getMonth()]}`;
}

function shortMoment(d: Date): string {
  return `${d.getDate()} ${MONTHS[d.getMonth()]}, ${pad(d.getHours())}:${pad(d.getMinutes())}`;
}
