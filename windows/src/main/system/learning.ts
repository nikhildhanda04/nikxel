import * as fs from "fs";
import * as path from "path";
import { cblog } from "../core/diag";
import { dayStamp, ensureDir, nikxelPath, readText, writeAtomic } from "../core/paths";
import { Settings } from "../core/settings";
import { ui } from "../core/ui";
import type { MOMGenerator } from "../recording/momGenerator";
import { SummaryTemplates } from "../recording/summaryTemplates";
import type { DayLogger } from "./dayLogger";
import * as Habits from "./habits";

/// What Nikxel learned from habits and edits, offered before anything changes: "I'm thinking
/// of… Will this suit you better?" A yes applies it; a no is remembered and never asked again;
/// at most one question a day. habits.ts decides what to suggest. State in
/// ~/.nikxel/learning.json, the user's summary fixes in ~/.nikxel/edits/instructions.jsonl.
/// Port of src/Learning.swift.

interface State { answered?: Record<string, boolean>; askedDay?: string; counts?: Record<string, number>; reviewedEditsAt?: number }
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
  if (offerSummaryTime(dayLogger) || offerAutoRecordCalls()) return;
  await offerRule(agent);
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
async function offerRule(agent: MOMGenerator): Promise<void> {
  const recent = edits(new Date(Date.now() - 30 * 86_400_000), ["meeting", "notes"]);
  const newest = Math.max(0, ...recent.map(e => e.t));
  if (recent.length < 2 || newest <= (load().reviewedEditsAt ?? 0)) return;
  update(s => { s.reviewedEditsAt = newest; });
  const decided = Object.keys(load().answered ?? {}).filter(k => k.startsWith("rule:")).map(k => k.slice(5));
  let reply: string;
  try { reply = await agent.runPrompt(Habits.rulePrompt(recent.map(e => e.text), decided), "learning-rule", "haiku"); } catch { return; }
  const r = Habits.parseRule(reply);
  if (!r) return;
  offer("rule:" + r.rule, "Your meeting summaries",
    `You've asked me this ${r.times} times${r.example ? ` ("${r.example}")` : ""}. I'm thinking of always doing it in your meeting summaries: ${r.rule}`,
    () => {
      const url = SummaryTemplates.activeURL, old = readText(url) ?? "";
      try {
        writeAtomic(url, old + (old.endsWith("\n") || !old ? "" : "\n") + `\n# Added by Nikxel after you said yes (${dayStamp(new Date())}):\n${r.rule}\n`);
      } catch { /* unwritable: the rule just isn't kept */ }
    });
}
