import * as fs from "fs";
import * as path from "path";

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
      const date = f.slice(0, 10);
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
  let s = joined();
  while ([...s].length > cap && bs.length > 1) {
    let i = bs.length - 1;
    for (let j = bs.length - 1; j >= 0; j--) if (bs[j].kind === "daily" && bs[j].date < cutoff) { i = j; break; }
    bs.splice(i, 1);
    s = joined();
  }
  return [...s].slice(0, cap).join("");
}

export function prompt(context: string, history: { q: string; a: string }[], question: string, today: Date): string {
  let p = `You are the user's desk avatar. Today is ${ymd(today)}. Answer using only the notes below. ` +
    `If the answer isn't in them, say so plainly; never guess. Reply in a few short lines or bullets, ` +
    `and name the meeting, person or date you got it from.\n\nNOTES:\n${context}\n`;
  for (const h of history) p += `\nUser: ${h.q}\nYou: ${h.a}\n`;
  return p + `\nUser: ${question}`;
}

/// A press-and-release on the avatar: under 4 px of travel with no second click opens (or closes) the chat.
/// 4 px or more was a drag; a second click is the recording double-click.
export function clickDecision(moved: number, secondClick: boolean): "chat" | "none" {
  return moved < 4 && !secondClick ? "chat" : "none";
}
