import * as fs from "fs";
import * as path from "path";
import { cblog } from "../core/diag";
import { Settings } from "../core/settings";
import { documentsRoot, nikxelPath, readText, writeAtomic } from "../core/paths";
import { ui } from "../core/ui";
import { MOMGenerator } from "../recording/momGenerator";
import * as A from "./automation";
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
const queue: { a: Automation; file: string | null }[] = [];
const runsFile = nikxelPath("automation-runs.json");

const withExt = (file: string, ext: string) => path.join(path.dirname(file), path.basename(file, path.extname(file)) + ext);

function tick(): void {
  const list = A.load(), now = new Date();
  let changed = false;
  for (const a of list) {
    if (!A.due(a, now)) continue;
    a.lastRun = A.minuteKey(now);
    changed = true;
    enqueue(a, null);
  }
  if (changed) A.save(list);
}

function enqueue(a: Automation, file: string | null): void {
  queue.push({ a, file });
  if (running === null) void next();
}

async function next(): Promise<void> {
  const item = queue.shift();
  if (!item || !agent) { running = null; Automations.onChange?.(); return; }
  const { a, file } = item;
  running = a.id;
  Automations.onChange?.();
  let attach = "";
  const md = file ? readText(file) : null;
  if (md !== null) {
    const what = ({ meeting: "the meeting summary that was just written", day: "today's day summary", week: "this week's summary" } as Record<string, string>)[a.trigger] ?? "the summary";
    attach = `### this automation's input: ${what}\n${md.slice(0, 15_000)}`;
  }
  const text = `Automation “${a.name}” (${A.when(a).toLowerCase()}): ${a.instruction}\n\nIf there's nothing to do, reply only SKIP.`;
  let r = { text: "", error: true };
  try { r = await new ChatSession(agent).send(text, attach); } catch (e) { r = { text: "⚠︎ " + (e as Error).message, error: true }; }
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
  // A card only when there's something to say and the avatar is up; the
  // window's Recent runs has every result either way.
  if (skipped || ui.avatar?.isVisible() !== true) return;
  const lines = text.split("\n").map(l => l.replace(/\*\*/g, "").trim()).filter(l => l);
  ui.tell({ icon: "⚡️", title: a.name, lines: [...lines.slice(0, 3), ...(lines.length > 3 ? ["…"] : [])],
    kind: error ? "warning" : "info", lifetime: 40, action: () => Automations.onOpen?.() });
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

  /// Run now, from the window: an event automation gets the latest summary of its kind.
  runNow(a: Automation): void {
    const kind = ({ meeting: "meetings", day: "daily", week: "weekly" } as Record<string, string>)[a.trigger];
    const latest = kind ? scan().find(s => s.kind === kind) : undefined;
    enqueue(a, latest ? withExt(latest.file, ".md") : null);
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
