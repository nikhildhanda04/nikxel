import * as fs from "fs";
import * as path from "path";
import { cblog } from "../core/diag";
import { Settings } from "../core/settings";
import { documentsRoot, nikxelPath, readText, writeAtomic } from "../core/paths";
import { ui } from "../core/ui";
import { MOMGenerator } from "../recording/momGenerator";
import * as A from "./automation";
import * as Attachments from "./attachments";
import { Automation } from "./automation";
import { build, localBlocks } from "./chatContext";
import { ChatSession } from "./chatSession";
import { scan } from "./summaryLibrary";

/// Runs the user's automations (automation.ts): the scheduled ones from a
/// timer, the rest when MeetingCoordinator or DayLogger finish a summary, and
/// any from the Nikxel window's Run now. One at a time, each through a fresh
/// ChatSession, so an automation can do what the chat can (answer, draft an
/// email, make an ERP task) and nothing more. Results go on a card and into
/// the window's Recent runs (~/.nikxel/automation-runs.json). Port of src/Automations.swift.

let agent: MOMGenerator | null = null;
let timer: NodeJS.Timeout | null = null;
let runs: any[] = [];
let running: string | null = null;
const queue: { a: Automation; file: string | null; picked: boolean }[] = [];
const runsFile = nikxelPath("automation-runs.json");

const withExt = (file: string, ext: string) => path.join(path.dirname(file), path.basename(file, path.extname(file)) + ext);

function tick(): void {
  const list = A.load(), now = new Date();
  let changed = false;
  for (const a of list) {
    if (!A.due(a, now)) continue;
    a.lastRun = A.minuteKey(now);
    if (a.date) a.enabled = false; // temporary: it ran, so it's done
    changed = true;
    enqueue(a, null);
  }
  if (changed) A.save(list);
}

function enqueue(a: Automation, file: string | null, picked = false): void {
  queue.push({ a, file, picked });
  if (running === null) void next();
}

async function next(): Promise<void> {
  const item = queue.shift();
  if (!item || !agent) { running = null; Automations.onChange?.(); return; }
  const { a, file, picked } = item;
  running = a.id;
  Automations.onChange?.();
  let attach = "";
  const md = file ? readText(file) : null;
  if (md !== null) {
    const what = ({ meeting: "the meeting summary that was just written", day: "today's day summary", week: "this week's summary" } as Record<string, string>)[a.trigger] ?? "the summary";
    attach = `### this automation's input: ${what}\n${md.slice(0, 15_000)}`;
  }
  // Its files (the SOP format…), every run.
  const files = (a.files ?? []).map(f => Attachments.block(f, "a file this automation follows")).filter((b): b is string => !!b);
  attach = [attach, ...files].filter(x => x).join("\n\n");
  // A one-time one is something they asked for on that day (a reminder): it always says something.
  const text = `Automation “${a.name}” (${A.when(a).toLowerCase()}): ${a.instruction}` +
    (picked ? "\n\nThe user picked this one themselves and asked for it now: do it, even if it doesn't look like the kind it's for."
      : a.date ? "" : "\n\nIf there's nothing to do, reply only SKIP.");
  let r = { text: "", error: true };
  try { r = await new ChatSession(agent).send(text, attach, true); } catch (e) { r = { text: "⚠︎ " + (e as Error).message, error: true }; }
  finished(a, file, r.text, r.error);
  void next();
}

function finished(a: Automation, file: string | null, reply: string, error: boolean): void {
  const text = reply.trim();
  const skipped = text.toUpperCase().startsWith("SKIP");
  const page = file ? withExt(file, ".html") : null;
  runs.unshift({ id: a.id, name: a.name, t: Date.now() / 1000, text: skipped ? "" : text,
    skipped, error, file: page && fs.existsSync(page) ? page : "" });
  runs = runs.slice(0, 60);
  try { writeAtomic(runsFile, JSON.stringify(runs)); } catch { /* the window still has them */ }
  cblog(`Automations: ran “${a.name}” → ${skipped ? "skip" : error ? "error" : `${text.length} chars`}`);
  // A card when there's something to say; the window's Recent runs has every result either way.
  // A reminder is shown even with the avatar hidden (tell falls back to a dialog), and waits while
  // nobody's at the computer; a repeating one only shows on the avatar.
  const once = !!a.date;
  if (skipped || (!once && ui.avatar?.isVisible() !== true)) return;
  const lines = text.split("\n").map(l => l.replace(/\*\*/g, "").trim()).filter(l => l);
  ui.tell({ icon: once ? "⏰" : "⚡️", title: a.name, lines: [...lines.slice(0, 3), ...(lines.length > 3 ? ["…"] : [])],
    kind: error ? "warning" : "info", lifetime: once ? Infinity : 40, action: () => Automations.onOpen?.() });
}

export const Automations = {
  /// The window redraws when a run finishes.
  onChange: null as (() => void) | null,
  /// Tapping a run's card: main.ts opens the window on Automations.
  onOpen: null as (() => void) | null,
  get runs(): any[] { return runs; },
  get running(): string | null { return running; },

  start(a: MOMGenerator): void {
    agent = a;
    try { const r = JSON.parse(readText(runsFile) ?? "[]"); runs = Array.isArray(r) ? r : []; } catch { runs = []; }
    if (timer) clearInterval(timer);
    timer = setInterval(tick, 20_000);
  },

  /// A summary was just written: "meeting", "day" or "week", with its .md.
  fire(trigger: string, mdFile: string | null): void {
    for (const a of A.load()) if (a.enabled && a.trigger === trigger) enqueue(a, mdFile);
  },

  /// Run now, from the window: an event automation gets the latest summary of its kind, or
  /// `picked`, one the user picked (Run on…), which it then does even if its test says skip.
  runNow(a: Automation, picked: string | null = null): void {
    const kind = ({ meeting: "meetings", day: "daily", week: "weekly" } as Record<string, string>)[a.trigger];
    const latest = picked ?? (kind ? scan().find(s => s.kind === kind)?.file : undefined);
    enqueue(a, latest ? withExt(latest, ".md") : null, !!picked);
  },

  // MARK: - Making them

  /// The user's request as an automation to review, or null.
  async make(request: string): Promise<Automation | null> {
    if (!agent) return null;
    try {
      const reply = await agent.runPrompt(A.makePrompt(request), "automation", "haiku", 60);
      return A.parse(reply)[0]?.a ?? null;
    } catch { return null; }
  },

  /// The chat's "remind me tomorrow to…": made and saved (switched on) straight away, so it really
  /// happens, and the reply says when.
  /// `files`: what the user attached in the chat (the SOP format…), given to it every run.
  async remind(request: string, ag: MOMGenerator, files: string[] = []): Promise<string> {
    const names = files.map(Attachments.name).filter((n): n is string => !!n);
    let a: Automation | undefined;
    try { a = A.parse(await ag.runPrompt(A.makePrompt(request, new Date(), names), "automation", "haiku", 60))[0]?.a; } catch { /* below */ }
    if (!a) return "I couldn't set that up. Add it under Automations → New, and say when it should run.";
    if (files.length) a.files = files;
    A.save([...A.load(), a]);
    Automations.onChange?.();
    cblog(`Automations: made “${a.name}” from chat (${A.when(a)})`);
    return a.date
      ? `Done: I'll remind you ${A.when(a).replace("Once, ", "")}. It's in Automations as a one-time automation (“${a.name}”) and switches itself off after it runs.`
      : `Done: “${a.name}” runs ${A.when(a).toLowerCase()}` + (names.length ? `, following ${names.map(n => `“${n}”`).join(", ")}` : "") +
        `. It's in Automations, where you can change or turn it off` + (a.trigger === "meeting" ? ", or run it on any meeting it skipped (Run on…)." : ".");
  },

  /// Automations suggested from the last two weeks of the user's work.
  async suggest(): Promise<{ a: Automation; why: string }[]> {
    if (!agent) return [];
    const existing = A.load();
    const context = [Settings.userContextBlock,
      build(localBlocks(path.join(documentsRoot(), "nikxel"), new Date()), 40_000)].join("\n\n");
    try {
      return A.parse(await agent.runPrompt(A.suggestPrompt(context, existing), "automation-suggest", "sonnet", 150));
    } catch { return []; }
  },
};
