import * as fs from "fs";
import * as path from "path";
import * as NoteName from "./noteName";
import { documentsRoot, HOME } from "../core/paths";

/// Builds the text the avatar chat answers from: the last 14 days of daily summaries, meeting minutes and notes
/// under ~/Documents/nikxel, plus the dashboard project feed. Electron-free. Port of ChatContext.swift.

/// Characters of context sent to the agent (measured in Task 2: see report).
export const CAP = 250_000;

export interface Block { kind: string; date: string; name: string; text: string }

const ymd = (d: Date) => `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`;
const daysAgo = (d: Date, n: number) => new Date(d.getFullYear(), d.getMonth(), d.getDate() - n);

/// Daily summaries, meeting minutes and notes dated within `days` days up to today, newest first
/// (daily, meeting, note within a day). Files whose first 10 characters aren't a date, or that don't end .md, are skipped.
export function localBlocks(root: string, today: Date, days = 14): Block[] {
  const end = ymd(today), start = ymd(daysAgo(today, days - 1));
  const out: Block[] = [];
  const dirs: [string, string][] = [["daily", "daily"], ["meeting", "meetings"], ["note", "notes"]];
  for (const [kind, sub] of dirs) {
    let files: string[] = [];
    try { files = fs.readdirSync(path.join(root, sub)); } catch { continue; }
    for (const f of files) {
      const date = NoteName.stamp(f.slice(0, -3)).slice(0, 10);  // "<name> <stamp>" once named
      if (!f.endsWith(".md") || !/^\d{4}-\d{2}-\d{2}$/.test(date) || date < start || date > end) continue;
      try { out.push({ kind, date, name: f.slice(0, -3), text: fs.readFileSync(path.join(root, sub, f), "utf8").trim() }); } catch { /* unreadable */ }
    }
  }
  const order: Record<string, number> = { daily: 0, meeting: 1, note: 2, project: 3 };
  return out.sort((a, b) => a.date !== b.date ? (a.date < b.date ? 1 : -1) : order[a.kind] - order[b.kind] || (a.name < b.name ? 1 : -1));
}

/// One block per project per day from the device project feed.
export function projectBlocks(feed: any[]): Block[] {
  const out: Block[] = [];
  for (const p of feed ?? []) {
    if (typeof p?.name !== "string") continue;
    for (const d of p.days ?? []) {
      if (typeof d?.date !== "string") continue;
      const lines: string[] = [];
      for (const m of d.meetings ?? []) lines.push(`Meeting: ${m.title ?? ""}${m.name ? ` (${m.name})` : ""}\n${m.body ?? ""}`);
      for (const i of d.items ?? []) lines.push(`- ${i.what ?? ""}${i.name ? ` (${i.name})` : ""}`);
      if (lines.length) out.push({ kind: "project", date: d.date, name: p.name, text: lines.join("\n") });
    }
  }
  return out;
}

/// Blocks newest first as "### kind · date · name" sections, at most `cap` characters. Over the cap,
/// daily summaries older than 2 days go first, then the oldest of anything; a lone block is cut to fit.
export function build(blocks: Block[], cap: number): string {
  const bs = [...blocks].sort((a, b) => a.date < b.date ? 1 : a.date > b.date ? -1 : 0); // stable
  const render = (b: Block) => `### ${b.kind} · ${b.date} · ${b.name}\n${b.text}`;
  const joined = () => bs.map(render).join("\n\n");
  const cutoff = ymd(daysAgo(new Date(), 2));
  // Each block's length once and a running total (plus "\n\n" between blocks): joining per drop was quadratic.
  const lens = bs.map(b => [...render(b)].length);
  let total = lens.reduce((a, n) => a + n, 0) + 2 * Math.max(bs.length - 1, 0);
  while (total > cap && bs.length > 1) {
    let i = bs.length - 1;
    for (let j = bs.length - 1; j >= 0; j--) if (bs[j].kind === "daily" && bs[j].date < cutoff) { i = j; break; }
    total -= lens[i] + 2;
    bs.splice(i, 1); lens.splice(i, 1);
  }
  return [...joined()].slice(0, cap).join("");
}

/// How to use Nikxel, for "how do I record a meeting?" or "where are my day summaries?". The Nikxel
/// window comes first; folders only as a second way. Port of ChatContext.appHelp.
const icon = process.platform === "linux" ? "the Nikxel icon at the right of the top bar" : "the Nikxel icon in the tray by the clock (under the ^ if it's hidden)";
export const APP_HELP = [
  `- Open the Nikxel window: click ${icon}, then Open Nikxel…. Everything below is in its sidebar.`,
  "- Record a meeting: double-click me (the avatar) to start, double-click again to stop. Or the Record button in the Nikxel window, or the tray icon. When it stops I write the meeting summary.",
  "- Chat with me: click me once on your screen, or Chat in the Nikxel window.",
  "- Meeting summaries: Library → Meetings in the Nikxel window. Open one to read, share, edit or rename it there.",
  "- Daily summaries: Library → Days; weekly ones: Library → Weeks. The time your day is written up: Recording & notes.",
  "- Notes (not meetings): Library → Notes. Switch between Meeting and Notes recording in Recording & notes.",
  "- Action items from meetings: Tasks. People you've met with: People.",
  "- Things to do every time (after a meeting, each morning): Automations. My suggestions about how you work, including any you missed on screen: Automations → What I've suggested.",
  "- WhatsApp replies and settings: WhatsApp. Google, Gmail, ERP and Slack: Connections. Your name, avatar and what I know about you: You.",
  "- What I did on WhatsApp today and AI cost: Activity. Folders, logs, updates, setup again and the tour again: Advanced.",
  "- Move me: drag me anywhere. Hide or show me, mute, record: the tray icon.",
  `- The files themselves, only if they ask for the folder: ${path.join(documentsRoot(), "nikxel")} (meetings, daily, weekly, notes), settings in ${path.join(HOME, ".nikxel")}. Advanced in the Nikxel window opens them.`,
].join("\n");

export function prompt(context: string, history: { q: string; a: string }[], question: string, today: Date): string {
  let p = `You are the user's desk avatar. Today is ${ymd(today)}. Answer using only the notes below. ` +
    `If the answer isn't in them, say so plainly; never guess. Reply in a few short lines or bullets, ` +
    `and name the meeting, person or date you got it from.\n\n` +
    `If the question is about Nikxel itself (how to do something, where something is), answer from HOW NIKXEL WORKS: ` +
    `point to the place in the Nikxel window first, and give a folder only as a second way or if they ask for files. ` +
    `End every answer about Nikxel with one short line saying that what Nikxel records and saves stays on this computer.\n\n` +
    `HOW NIKXEL WORKS:\n${APP_HELP}\n\nNOTES:\n${context}\n`;
  for (const h of history) p += `\nUser: ${h.q}\nYou: ${h.a}\n`;
  return p + `\nUser: ${question}`;
}

/// A press-and-release on the avatar: under 4 px of travel with no second click opens (or closes) the chat.
/// 4 px or more was a drag; a second click is the recording double-click.
export function clickDecision(moved: number, secondClick: boolean): "chat" | "none" {
  return moved < 4 && !secondClick ? "chat" : "none";
}
