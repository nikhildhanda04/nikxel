import * as fs from "fs";
import * as path from "path";
import { cblog } from "../core/diag";
import { dayStamp, documentsDir, ensureDir, nikxelPath, readText, writeAtomic } from "../core/paths";
import { Settings } from "../core/settings";
import { ui } from "../core/ui";
import type { MOMGenerator } from "../recording/momGenerator";
import { SummaryTemplates } from "../recording/summaryTemplates";
import type { DayLogger } from "./dayLogger";
import * as ERP from "./erp";
import * as Habits from "./habits";
import * as Suggestions from "./suggestions";
import { WhatsAppActivityLogger } from "../whatsapp/whatsAppActivityLogger";

/// What Nikxel learned from habits and edits, offered before anything changes: "I'm thinking
/// of… Will this suit you better?" A yes applies it; a no is remembered and never asked again;
/// at most one question a day. habits.ts decides what to suggest. State in
/// ~/.nikxel/learning.json, the user's summary fixes in ~/.nikxel/edits/instructions.jsonl.
/// Port of src/Learning.swift.

interface Queued { action: string; params: Record<string, string>; line: string; evidence: string; at: number }
interface State {
  answered?: Record<string, boolean>; askedDay?: string; counts?: Record<string, number>; reviewedEditsAt?: number
  suggestedWeek?: string; queued?: Queued[]
}
const file = () => nikxelPath("learning.json");
const editsFile = () => nikxelPath("edits", "instructions.jsonl");

function load(): State {
  try { return JSON.parse(readText(file()) ?? "{}"); } catch { return {}; }
}
function update(change: (s: State) => void): void {
  const s = load();
  change(s);
  try { writeAtomic(file(), JSON.stringify(s, null, 2)); } catch { /* unwritable home */ }
}

// MARK: - Asking

/// Asks unless `key` was answered before or something was already asked today. True when it asked.
export function offer(key: string, title: string, line: string, apply: () => void): boolean {
  const today = dayStamp(new Date());
  const s = load();
  if (s.answered?.[key] !== undefined || s.askedDay === today) return false;
  update(x => { x.askedDay = today; });
  cblog(`Learning: asking ${key}`);
  ui.ask({ icon: "💡", title, lines: [line, "Will this suit you better?"], buttons: [
    { title: "Yes, do it", action: () => { answer(key, true); apply(); } },
    { title: "No thanks", action: () => answer(key, false) },
  ] });
  return true;
}

function answer(key: string, yes: boolean): void {
  cblog(`Learning: ${key} → ${yes ? "yes" : "no"}`);
  update(s => { s.answered = { ...s.answered, [key]: yes }; });
}

export function count(name: string): void {
  update(s => { s.counts = { ...s.counts, [name]: (s.counts?.[name] ?? 0) + 1 }; });
}
const counter = (name: string) => load().counts?.[name] ?? 0;

// MARK: - Edits

/// One fix the user typed into a summary's Edit box, kept so repeated ones can become a standing rule.
export function logEdit(instruction: string, page: string): void {
  const kind = /[\\/]meetings[\\/]/.test(page) ? "meeting" : /[\\/]daily[\\/]/.test(page) ? "daily"
    : /[\\/]weekly[\\/]/.test(page) ? "weekly" : "notes";
  try {
    ensureDir(path.dirname(editsFile()));
    fs.appendFileSync(editsFile(), JSON.stringify({ t: Date.now() / 1000, kind, text: instruction }) + "\n");
  } catch { /* a lost fix only means one less signal */ }
}

function edits(since: Date, kinds?: string[]): { t: number; text: string }[] {
  const out: { t: number; text: string }[] = [];
  for (const line of (readText(editsFile()) ?? "").split("\n")) {
    try {
      const o = JSON.parse(line);
      if (typeof o.t === "number" && o.t >= since.getTime() / 1000 && typeof o.text === "string"
          && (!kinds || kinds.includes(o.kind))) out.push({ t: o.t, text: o.text });
    } catch { /* blank or torn line */ }
  }
  return out;
}

/// The day's summary fixes, for the profile merge: "Speaker 2 is Prince" teaches a name.
export function editsBlock(since: Date): string {
  const e = edits(since);
  return e.length ? "\n\nFixes the user typed into their summaries (names and terms here are corrections worth learning):\n"
    + e.map(x => `- ${x.text}`).join("\n") : "";
}

// MARK: - Once a day

/// After the day summary: the first thing worth asking about, if any.
export async function daily(dayLogger: DayLogger, agent: MOMGenerator): Promise<void> {
  if (offerSummaryTime(dayLogger) || offerAutoRecordCalls() || await offerRule(agent)) return;
  offerQueued(dayLogger);
}

function offerSummaryTime(dayLogger: DayLogger): boolean {
  const current = Settings.summaryMinutes;
  const t = Habits.summaryTime(Habits.dayEnds(dayLogger.recentSamples(), new Date()), current);
  if (t === null) return false;
  return offer("summaryTime", "Your day summary",
    `You usually wrap up by about ${Habits.clock(t - 30)}. I'm thinking of writing your day summary at ${Habits.clock(t)} instead of ${Habits.clock(current)}.`,
    () => { Settings.summaryMinutes = t; dayLogger.reschedule(); });
}

function offerAutoRecordCalls(): boolean {
  const recorded = counter("call.record"), skipped = counter("call.skip");
  if (Settings.autoRecordCalls || !Habits.offerAutoRecord(recorded, skipped)) return false;
  return offer("autoRecord", "Recording your calls",
    `You've recorded ${recorded} of the ${recorded + skipped} calls I asked about. I'm thinking of starting the recording myself when a call begins — you'll see it, and a double-click stops it.`,
    () => { Settings.autoRecordCalls = true; });
}

/// Repeated summary fixes → one standing rule for meeting summaries, added to the active
/// summary template on a yes. Looks only when there are fixes it hasn't looked at.
async function offerRule(agent: MOMGenerator): Promise<boolean> {
  const recent = edits(new Date(Date.now() - 30 * 86_400_000), ["meeting", "notes"]);
  const newest = Math.max(0, ...recent.map(e => e.t));
  if (recent.length < 2 || newest <= (load().reviewedEditsAt ?? 0)) return false;
  update(s => { s.reviewedEditsAt = newest; });
  const decided = Object.keys(load().answered ?? {}).filter(k => k.startsWith("rule:")).map(k => k.slice(5));
  let reply: string;
  try { reply = await agent.runPrompt(Habits.rulePrompt(recent.map(e => e.text), decided), "learning-rule", "haiku"); } catch { return false; }
  const r = Habits.parseRule(reply);
  if (!r) return false;
  return offer("rule:" + r.rule, "Your meeting summaries",
    `You've asked me this ${r.times} times${r.example ? ` ("${r.example}")` : ""}. I'm thinking of always doing it in your meeting summaries: ${r.rule}`,
    () => addRule(r.rule));
}

/// A standing instruction appended to the active summary template -- a yes from the daily rule check or the weekly review.
function addRule(rule: string): void {
  const url = SummaryTemplates.activeURL, old = readText(url) ?? "";
  try {
    writeAtomic(url, old + (old.endsWith("\n") || !old ? "" : "\n") + `\n# Added by Nikxel after you said yes (${dayStamp(new Date())}):\n${rule}\n`);
  } catch { /* unwritable: the rule just isn't kept */ }
}

// MARK: - Once a week

/// The catalogue's settings as they stand now.
function settingsNow(): Suggestions.Settings {
  return { summaryMinutes: Settings.summaryMinutes, autoRecordCalls: Settings.autoRecordCalls, waDraftOnly: Settings.waDraftOnly,
    waQuietHours: Settings.waQuietHours, waQuietFrom: Settings.waQuietFrom, waQuietTo: Settings.waQuietTo, waChatTasks: Settings.waChatTasks,
    summaryTemplate: Settings.summaryTemplate, templates: SummaryTemplates.available().map(t => t.slug) };
}

/// Meetings whose file name dates them in `days`: start from the name, end from the file's last write, title from its "# " line.
function meetings(days: Set<string>): Suggestions.Meeting[] {
  const dir = documentsDir("meetings"), out: Suggestions.Meeting[] = [];
  let names: string[] = [];
  try { names = fs.readdirSync(dir); } catch { /* no meetings yet */ }
  for (const name of names) {
    const m = /^(\d{4})-(\d{2})-(\d{2})-(\d{2})(\d{2})(\d{2})?\.md$/.exec(name);
    if (!m || !days.has(name.slice(0, 10))) continue;  // also skips .transcript files
    const start = new Date(+m[1], +m[2] - 1, +m[3], +m[4], +m[5], +(m[6] ?? 0)).getTime() / 1000;
    let end: number;
    try { end = fs.statSync(path.join(dir, name)).mtimeMs / 1000; } catch { continue; }
    const head = (readText(path.join(dir, name)) ?? "").split("\n").find(l => l.startsWith("# "));
    out.push({ start, end, title: head ? head.slice(2) : name.slice(0, -3) });
  }
  return out;
}

/// The weekly review, run inside the week in review's background work: the week's digest to the AI once per `weekKey`,
/// advice back as an "## Ideas for you" section, offers queued for `offerQueued`. "" when there's nothing or it already ran.
export async function weekly(dayLogger: DayLogger, agent: MOMGenerator, weekKey: string): Promise<string> {
  if (load().suggestedWeek === weekKey) return "";
  update(s => { s.suggestedWeek = weekKey; });  // before the call: never twice
  try {
    const [y, mo, d] = weekKey.split("-").map(Number), end = new Date(y, mo - 1, d);  // that day's midnight
    const days = [1, 2, 3, 4, 5, 6, 7].map(back => new Date(y, mo - 1, d - back, 12));
    const answered = Object.keys(load().answered ?? {}).sort();
    const settings = settingsNow(), erp: Suggestions.Input["erp"] = [];
    for (const day of [...days].reverse()) for (const t of await ERP.tasksTouched(day)) erp.push({ day: dayStamp(day), name: t.name, project: t.project });
    const input: Suggestions.Input = {
      samples: dayLogger.weekSamples(end), meetings: meetings(new Set(days.map(day => dayStamp(day)))),
      chats: days.flatMap(day => WhatsAppActivityLogger.readLog("chats", day)),
      bot: days.flatMap(day => WhatsAppActivityLogger.readLog("bot", day)),
      edits: edits(new Date(y, mo - 1, d - 7), ["meeting", "notes"]).map(e => e.text),
      erp, settings, declined: answered,
    };
    const context = [dayLogger.roleGuidance(), Settings.userContextBlock].filter(Boolean).join("\n\n");
    const reply = await agent.runPrompt(Suggestions.prompt(Suggestions.digest(input), context), "weekly-suggestions");
    const advice: string[] = [], queued: Queued[] = [];
    for (const item of Suggestions.parse(reply, settings, new Set(answered))) {
      if (item.kind === "advice") advice.push(`- ${item.text}${item.evidence ? ` — ${item.evidence}` : ""}`);
      else queued.push({ action: item.action, params: item.params, line: item.line, evidence: item.evidence, at: Date.now() / 1000 });
    }
    update(s => { s.queued = queued; });
    cblog(`Learning: weekly suggestions ${weekKey}: ${advice.length} advice, ${queued.length} offers`);
    return advice.length ? "## Ideas for you\n" + advice.join("\n") + "\n" : "";
  } catch (e) {
    cblog(`Learning: weekly suggestions failed: ${e instanceof Error ? e.message : e}`);
    return "";
  }
}

/// The weekly review's offers, one a day: older than 14 days, answered, or no longer changing anything drops out first.
function offerQueued(dayLogger: DayLogger): void {
  const s = load(), now = Date.now() / 1000, answered = new Set(Object.keys(s.answered ?? {})), settings = settingsNow();
  // Through `parse` again so the same rules decide: valid, unanswered, still changing something.
  const live = (s.queued ?? []).filter(q => typeof q.at === "number" && now - q.at < 14 * 86_400
    && Suggestions.parse(JSON.stringify({ items: [{ ...q, kind: "offer" }] }), settings, answered).length > 0);
  const q = live[0];
  const asked = !!q && offer(Suggestions.key(q.action, q.params), "An idea for your week",
    q.evidence ? `${q.line} (${q.evidence})` : q.line, () => apply(q.action, q.params, dayLogger));
  update(x => { x.queued = asked ? live.slice(1) : live; });
}

/// What a yes to a weekly offer does, per catalogue action.
function apply(action: string, p: Record<string, string>, dayLogger: DayLogger): void {
  switch (action) {
    case "summaryTime": Settings.summaryMinutes = Number(p.minutes); dayLogger.reschedule(); break;
    case "autoRecordCalls": Settings.autoRecordCalls = true; break;
    case "waDraftOnly": Settings.waDraftOnly = true; break;
    case "waChatTasks": Settings.waChatTasks = true; break;
    case "waQuietHours": Settings.waQuietHours = true; Settings.waQuietFrom = Number(p.from); Settings.waQuietTo = Number(p.to); break;
    case "summaryTemplate": Settings.summaryTemplate = p.name; break;
    case "summaryRule": addRule(p.text); break;
    default: cblog(`Learning: unknown weekly action ${action}`);
  }
}
