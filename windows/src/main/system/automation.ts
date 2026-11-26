import * as crypto from "crypto";
import * as path from "path";
import { ensureDir, nikxelPath, readText, writeAtomic } from "../core/paths";

/// A user's automation: when something happens (a meeting summary, the day or
/// week summary, or a time), Nikxel carries out a plain-English instruction
/// through the chat (ChatSession), which can answer, draft an email or make an
/// ERP task, and never sends mail by itself. Kept in ~/.nikxel/automations.json.
/// automations.ts runs them; this file has no Electron, so
/// checks/automation.test.ts can cover the rules. Port of src/Automation.swift.
export interface Automation {
  id: string;
  name: string;
  /// "meeting", "day", "week" or "schedule".
  trigger: string;
  /// For "schedule": "HH:mm", and "daily", "weekdays" or "mon"…"sun".
  time: string;
  days: string;
  instruction: string;
  enabled: boolean;
  /// "yyyy-MM-dd HH:mm" of the last scheduled run, so a minute is never run twice.
  lastRun: string;
  /// A temporary one ("remind me tomorrow…"): "yyyy-MM-dd". It runs once, that day at `time` (or as soon
  /// as Nikxel is next awake after it), then switches itself off. null: it repeats on `days`.
  date: string | null;
  /// Files it follows every run (attachments ids), e.g. the user's SOP format. null: none.
  files: string[] | null;
}

export const TRIGGERS = ["meeting", "day", "week", "schedule"];
export const WEEKDAYS = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"];
const DAY_NAMES: Record<string, string> = { sun: "Sunday", mon: "Monday", tue: "Tuesday", wed: "Wednesday", thu: "Thursday", fri: "Friday", sat: "Saturday" };

/// An automation with the Swift struct's defaults filled in.
export function make(p: Partial<Automation> & { instruction: string }): Automation {
  return { id: "", name: "", trigger: "schedule", time: "09:00", days: "daily", enabled: true, lastRun: "", date: null, files: null, ...p };
}

const pad = (n: number) => String(n).padStart(2, "0");

/// "After every meeting", "Weekdays at 09:00"…
export function when(a: Automation, now = new Date()): string {
  if (a.date && a.trigger === "schedule") {
    const d = dayDate(a.date), key = (x: Date) => x.toDateString(), tmr = new Date(now); tmr.setDate(now.getDate() + 1);
    const day = !d ? a.date : key(d) === key(now) ? "today" : key(d) === key(tmr) ? "tomorrow"
      : d.toLocaleDateString("en-GB", { weekday: "short", day: "numeric", month: "short" }).replace(",", "");
    return `Once, ${day} at ${a.time}`;
  }
  switch (a.trigger) {
    case "meeting": return "After every meeting summary";
    case "day": return "After your day summary";
    case "week": return "After your week summary";
    default: {
      const d = a.days === "daily" ? "Every day" : a.days === "weekdays" ? "Weekdays" : "Every " + (DAY_NAMES[a.days] ?? a.days);
      return `${d} at ${a.time}`;
    }
  }
}

/// Due at `now` (a schedule whose minute it is, not already run this minute).
/// `utc` reads the clock in UTC instead of local time (the Swift's calendar argument, for checks).
export function due(a: Automation, now: Date, utc = false): boolean {
  if (!a.enabled || a.trigger !== "schedule") return false;
  if (a.date) {
    // Late is fine (the computer was asleep at 9): it still runs, once.
    const m = /^(\d{4})-(\d\d)-(\d\d)$/.exec(a.date), hm = a.time.split(":").map(Number);
    if (a.lastRun || !m || hm.length !== 2) return false;
    const at = utc ? new Date(Date.UTC(+m[1], +m[2] - 1, +m[3], hm[0], hm[1])) : new Date(+m[1], +m[2] - 1, +m[3], hm[0], hm[1]);
    return now >= at;
  }
  const h = utc ? now.getUTCHours() : now.getHours(), m = utc ? now.getUTCMinutes() : now.getMinutes();
  if (`${pad(h)}:${pad(m)}` !== a.time) return false;
  const wd = WEEKDAYS[utc ? now.getUTCDay() : now.getDay()];
  const dayOK = a.days === "daily" || (a.days === "weekdays" && !["sat", "sun"].includes(wd)) || a.days === wd;
  return dayOK && a.lastRun !== minuteKey(now, utc);
}

/// A "yyyy-MM-dd" as a local date, or null.
export function dayDate(s: string | null): Date | null {
  const m = /^(\d{4})-(\d\d)-(\d\d)$/.exec(s ?? "");
  const d = m ? new Date(+m[1], +m[2] - 1, +m[3]) : null;
  return d && d.getMonth() === +m![2] - 1 ? d : null;
}

export function minuteKey(d: Date, utc = false): string {
  const [y, mo, da, h, mi] = utc
    ? [d.getUTCFullYear(), d.getUTCMonth() + 1, d.getUTCDate(), d.getUTCHours(), d.getUTCMinutes()]
    : [d.getFullYear(), d.getMonth() + 1, d.getDate(), d.getHours(), d.getMinutes()];
  return `${y}-${pad(mo)}-${pad(da)} ${pad(h)}:${pad(mi)}`;
}

/// Anything the agent or the page sends, made valid: a known trigger, a real
/// HH:mm, a known day set, a name. null when there's no instruction.
export function clean(src: Automation): Automation | null {
  const a = { ...src };
  a.instruction = (a.instruction ?? "").trim();
  if (!a.instruction) return null;
  a.name = (a.name ?? "").trim();
  if (!a.name) a.name = a.instruction.slice(0, 48);
  if (!TRIGGERS.includes(a.trigger)) a.trigger = "schedule";
  const hm = String(a.time ?? "").split(":").filter(x => /^[+-]?\d+$/.test(x)).map(Number);
  a.time = hm.length === 2 && hm[0] >= 0 && hm[0] < 24 && hm[1] >= 0 && hm[1] < 60 ? `${pad(hm[0])}:${pad(hm[1])}` : "09:00";
  if (!["daily", "weekdays", ...WEEKDAYS].includes(a.days)) a.days = "daily";
  if (typeof a.enabled !== "boolean") a.enabled = true;
  if (typeof a.lastRun !== "string") a.lastRun = "";
  if (a.trigger !== "schedule" || !dayDate(a.date)) a.date = null;
  if (!a.id) a.id = crypto.randomUUID().toUpperCase();
  return a;
}

// MARK: - Ideas

/// Ready-made ones, shown before Nikxel has suggested any of its own.
export const IDEAS: Automation[] = [
  make({ name: "Follow-up email after client calls", trigger: "meeting",
    instruction: "If this was a call with a client or someone outside my company, draft a short follow-up email to them with what we agreed and the next steps, with owners and dates. If it was internal, reply SKIP." }),
  make({ name: "My tasks from every meeting", trigger: "meeting",
    instruction: "List only the action items I own from this meeting, with their due dates, as a short checklist. If I own none, reply SKIP." }),
  make({ name: "Morning brief", trigger: "schedule", time: "09:00", days: "weekdays",
    instruction: "Give me a short brief for today: my open tasks, anything I promised someone that is due soon, and who is waiting on me on WhatsApp or email." }),
  make({ name: "Friday wrap-up", trigger: "schedule", time: "17:00", days: "fri",
    instruction: "Summarise my week in five bullets: what got done, what's still open, and what I should start Monday with." }),
  make({ name: "Blocked work alert", trigger: "day",
    instruction: "From today's summary, list anything that is blocked and who it is waiting on, with a one-line nudge I could send them. If nothing is blocked, reply SKIP." }),
  make({ name: "Make ERP tasks from my meetings", trigger: "meeting",
    instruction: "Make a task in ERP for the most important action item I own from this meeting, with its due date. If I own none, reply SKIP." }),
  make({ name: "Unanswered messages at lunch", trigger: "schedule", time: "13:00", days: "weekdays",
    instruction: "Who has been waiting on a reply from me on WhatsApp or email since this morning? List them with what they asked, most urgent first. If no one, reply SKIP." }),
  make({ name: "Weekly people check-in", trigger: "week",
    instruction: "From this week, list the people I owe something to and what it is, so I can clear it before Monday." }),
];

// MARK: - Asking the agent

export const SHAPE = `{"name": "short name", "trigger": "meeting|day|week|schedule", "time": "HH:mm", "days": "daily|weekdays|mon|tue|wed|thu|fri|sat|sun", "date": "yyyy-MM-dd, only for a one-time one (a reminder or a task for a given day); leave it out for a repeating one", "instruction": "what Nikxel should do, written to Nikxel, ending with: If there's nothing to do, reply SKIP."}`;

export const CAN =
  "What an automation can do when it runs (it is carried out by Nikxel's chat, which can see the user's " +
  "meeting minutes, day and week summaries and notes from the last 14 days, their team projects, WhatsApp " +
  "chats when WhatsApp is open, their Gmail inbox when Google is connected, and their ERP when connected): " +
  "answer or summarise something and show it to the user; read the open tasks in ERP (who they're for, " +
  "stage, deadline); draft an email in Gmail (never send it); make a task in ERP. It cannot send WhatsApp messages or emails by itself.\n" +
  "Triggers: \"meeting\" runs after every meeting summary (the summary is given to it), \"day\" after the " +
  "end-of-day summary, \"week\" after the weekly summary, \"schedule\" at a time on given days, or once on a " +
  "\"date\" (then it switches itself off). It can be given files the user attached (a template or format to " +
  "follow, a price list), which it gets every time it runs. An automation can be for only some " +
  "meetings (client calls, ones where an SOP is needed): it decides from each meeting's summary.";

/// Turn the user's request into one automation.
export function makePrompt(request: string, now = new Date(), files: string[] = []): string {
  const stamp = `${now.toLocaleDateString("en-US", { weekday: "long" })} ${minuteKey(now)}`;
  return `The user wants Nikxel to set up an automation. ${CAN}
It's ${stamp} now. Something for one day ("remind me tomorrow morning to…", "on Friday ` +
    `check…", "at 5 to…") is a one-time "schedule" with a "date"; "every…", "each…" or "after meetings" repeats. ` +
    `Morning is 09:00, afternoon 14:00, evening 18:00, unless they say a time. For a reminder the ` +
    `instruction is "Remind me to <what they said>, in one or two short lines, adding anything useful you ` +
    `can see about it." and never ends with SKIP. Name it after the task, e.g. "Remind: call Vikas". ` +
    `If they want it only for some meetings or days (e.g. "only client calls", "when an SOP is needed"), ` +
    `start the instruction with that test spelled out, e.g. "If this was a call with a client or someone ` +
    `outside my company where a process was agreed, …; otherwise reply SKIP."` +
    (files.length ? ` The user attached ${files.map(f => `“${f}”`).join(", ")} for it; it gets the file every run, so the instruction says to follow it by name, e.g. "write an SOP in the exact format of “${files[0]}”".` : "") + `

Reply with only one JSON object, no prose, in this shape:
${SHAPE}

The user's request: ${request}`;
}

/// Suggest automations from what the user's recent work looks like.
export function suggestPrompt(context: string, existing: Automation[]): string {
  const names = existing.map(a => a.name).join("; ");
  return "Suggest 4 automations that would genuinely save this user time, based on their recent work below. " +
    "Make them specific to the people, clients, projects and routines you can see, not generic. " +
    `Don't repeat any they already have. ${CAN}

Reply with only a JSON array of objects, no prose, each in this shape plus a "why" field ` +
    `(one sentence on what you saw that made you suggest it):
${SHAPE}

Automations they already have: ${names || "none"}

Their recent work:
${context.slice(0, 40_000)}`;
}

/// The first JSON object or array in an agent's reply, as automations
/// (with "why" when the agent gave one). Invalid ones are dropped.
export function parse(reply: string): { a: Automation; why: string }[] {
  const o = reply.search(/[{[]/);
  const c = Math.max(reply.lastIndexOf("}"), reply.lastIndexOf("]"));
  if (o < 0 || c < 0 || o >= c) return [];
  let any: unknown;
  try { any = JSON.parse(reply.slice(o, c + 1)); } catch { return []; }
  const isObj = (x: unknown): x is Record<string, unknown> => typeof x === "object" && x !== null && !Array.isArray(x);
  const list = Array.isArray(any) ? (any.every(isObj) ? any : []) : isObj(any) ? [any] : [];
  const str = (v: unknown, d: string) => (typeof v === "string" ? v : d);
  const out: { a: Automation; why: string }[] = [];
  for (const d of list) {
    const a = clean(make({ name: str(d.name, ""), trigger: str(d.trigger, ""), time: str(d.time, "09:00"),
      days: str(d.days, "daily").toLowerCase(), instruction: str(d.instruction, ""), date: typeof d.date === "string" ? d.date : null,
      files: Array.isArray(d.files) && d.files.length ? d.files.map(String) : null }));
    if (a) out.push({ a, why: str(d.why, "") });
  }
  return out;
}

// MARK: - Store

/// Settable so checks can point it at a temp file.
export const store = { file: nikxelPath("automations.json") };

export function load(): Automation[] {
  const text = readText(store.file);
  if (!text) return [];
  try {
    const list = JSON.parse(text);
    return Array.isArray(list) ? list.map(d => make({ ...d, instruction: String(d.instruction ?? ""), date: typeof d.date === "string" ? d.date : null,
      files: Array.isArray(d.files) && d.files.length ? d.files.map(String) : null })) : [];
  } catch { return []; }
}

/// Pretty-printed with sorted keys, like the Mac's JSONEncoder, so both read the same file.
export function save(list: Automation[]): void {
  ensureDir(path.dirname(store.file));
  // date and files only when set, as Swift's encoder leaves out a nil.
  const sorted = list.map(a => ({ ...(a.date ? { date: a.date } : {}), days: a.days, enabled: a.enabled, ...(a.files?.length ? { files: a.files } : {}), id: a.id, instruction: a.instruction,
    lastRun: a.lastRun, name: a.name, time: a.time, trigger: a.trigger }));
  writeAtomic(store.file, JSON.stringify(sorted, null, 2));
}

export function dict(a: Automation): Record<string, unknown> {
  return { id: a.id, name: a.name, trigger: a.trigger, time: a.time, days: a.days, instruction: a.instruction, enabled: a.enabled, when: when(a),
    date: a.date, done: !!a.date && !!a.lastRun, files: a.files ?? [] };
}

/// "Remind me…", "set a reminder…": the chat makes an automation for it instead of only saying it will.
export function looksLikeReminder(text: string): boolean {
  return /\b(remind me|(set|add|make|create) (me )?(an? )?reminder|nudge me|ping me|don'?t let me forget|(set up|add|make|create) (an? )?automation)\b/i.test(text);
}
