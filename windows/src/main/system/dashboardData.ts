import * as fs from "fs";
import * as path from "path";
import type { LibraryEntry } from "./summaryLibrary";

/// Port of DashboardData.swift.
///
/// What the Nikxel window's Tasks, People and Activity sections are built from,
/// read straight from the summaries on disk each time (so an edit or a new
/// meeting shows up on the next look). src/checks/dashboardData.test.ts covers
/// the parsing.

export interface Item { n: number; done: boolean; text: string; owner: string; due: string }

const isActionItems = (raw: string) => raw.slice(3).trim().toLowerCase() === "action items";

/// A meeting's "## Action Items", numbered from 1 the way NotePage numbers
/// its checkboxes (task-1, task-2…), so a tick here can tick the page too.
export function actionItems(md: string): Item[] {
  const out: Item[] = [];
  let inside = false;
  for (const raw of md.split("\n")) {
    if (raw.startsWith("## ")) { inside = isActionItems(raw); continue; }
    const t = inside ? task(raw) : null;
    if (!t || isNone(t[1])) continue;
    const [text, fields] = splitFields(t[1]);
    const field = (k: string) => {
      const v = (fields.find(f => f.key.toLowerCase() === k)?.value ?? "").trim();
      return unset(v) ? "" : v;
    };
    out.push({ n: out.length + 1, done: t[0], text: text.replace(/\*\*/g, "").trim(), owner: field("owner"), due: field("due") });
  }
  return out;
}

/// The md with action item `n` ticked or unticked; null if there's no such item.
export function markItem(md: string, n: number, done: boolean): string | null {
  const lines = md.split("\n");
  let inside = false, seen = 0;
  for (let k = 0; k < lines.length; k++) {
    const raw = lines[k];
    if (raw.startsWith("## ")) { inside = isActionItems(raw); continue; }
    const t = inside ? task(raw) : null;
    if (!t || isNone(t[1])) continue;
    seen += 1;
    if (seen !== n || !/\[[ xX]\]/.test(raw)) continue;
    lines[k] = raw.replace(/\[[ xX]\]/, done ? "[x]" : "[ ]");
    return lines.join("\n");
  }
  return null;
}

/// "- [ ] item" / "- [x] item".
function task(raw: string): [boolean, string] | null {
  const t = raw.trim();
  if (!(t.startsWith("- [") || t.startsWith("* [")) || Array.from(t).length <= 6) return null;
  const box = t.slice(2, 6).toLowerCase();
  if (box !== "[ ] " && box !== "[x] ") return null;
  return [box === "[x] ", t.slice(6)];
}

// Same rules as NoteExporter.isNone / splitFields, which can't be built on their own.
function isNone(text: string): boolean {
  const t = text.toLowerCase().trim();
  return t === "none" || t === "none." || t.startsWith("none —") || t.startsWith("none -");
}

function splitFields(item: string): [string, { key: string; value: string }[]] {
  const text: string[] = [], out: { key: string; value: string }[] = [];
  item.split(" — ").forEach((part, i) => {
    const colon = part.indexOf(":");
    if (i === 0 || colon < 0) { text.push(part); return; }
    const key = part.slice(0, colon).trim(), value = part.slice(colon + 1).trim();
    if (!key || Array.from(key).length > 12 || !value || !/^[\p{L} ]+$/u.test(key)) { text.push(part); return; }
    out.push({ key, value });
  });
  return [text.join(" — "), out];
}

export function unset(v: string): boolean {
  const l = v.toLowerCase();
  return !l || l.startsWith("not specified") || l.startsWith("not stated") || l.startsWith("unassigned") || l === "tbd" || l === "none";
}

/// "## Attendees" names: "- Ali Rajeh: client" → "Ali Rajeh". The user
/// ("Me", "Nikhil (Me)") and "Others" are left out.
export function attendees(md: string): string[] {
  const out: string[] = [];
  let inside = false;
  for (const raw of md.split("\n")) {
    if (raw.startsWith("## ")) { inside = raw.slice(3).trim().toLowerCase() === "attendees"; continue; }
    if (!inside || !(raw.startsWith("- ") || raw.startsWith("* "))) continue;
    let name = raw.slice(2);
    if (isMe(name.split(":")[0])) continue;
    for (const sep of [":", " — ", " – ", " - ", " ("]) { const r = name.indexOf(sep); if (r >= 0) name = name.slice(0, r); }
    const n = person(name);
    if (n != null && !out.includes(n)) out.push(n);
  }
  return out;
}

/// A name as a person to list: notes like "*(likely)*" or "(not on call)"
/// dropped; null for the user, "Others", "Speaker 2", "Nikhil's side", "Unassigned".
export function person(raw: string): string | null {
  if (isMe(raw)) return null;
  const name = raw.replace(/\*?\([^)]*\)\*?|\*\*|\*/g, "").trim();
  const l = name.toLowerCase();
  if (Array.from(name).length <= 1 || unset(name) || l.startsWith("other") || l.startsWith("speaker") || l.startsWith("unknown")
    || l.includes("'s side") || l.includes("’s side") || l.startsWith("everyone") || l.startsWith("all ")) return null;
  return name;
}

/// "Nikhil (Me)", "Me", "Me (Nikhil)".
export function isMe(name: string): boolean {
  const l = name.toLowerCase();
  return l === "me" || l.includes("(me)") || l.startsWith("me ");
}

/// Lines of each summary that contain every word of `query`, for the Library's search.
/// `md` is the summary's .md path.
export function search(query: string, files: { id: string; md: string }[], limit = 60): { id: string; match: string }[] {
  const words = query.toLowerCase().split(" ").filter(w => w);
  if (!words.length) return [];
  const out: { id: string; match: string }[] = [];
  for (const f of files) {
    let text: string;
    try { text = fs.readFileSync(f.md, "utf8"); } catch { continue; }
    const lower = text.toLowerCase();
    if (!words.every(w => lower.includes(w))) continue;
    const line = text.split("\n").find(l => words.some(w => l.toLowerCase().includes(w))) ?? "";
    const clean = line.replace(/^[#\-*>\s\[\]xX]+|\*\*|`/g, "");
    out.push({ id: f.id, match: Array.from(clean.trim()).slice(0, 180).join("") });
    if (out.length === limit) break;
  }
  return out;
}

/// The WhatsApp replies the bot sent on `day`, newest first, from
/// WhatsAppActivityLogger's bot-yyyy-MM-dd.jsonl.
export function botReplies(day: Date, dir: string): { t: number; name: string; text: string }[] {
  const p = (n: number) => String(n).padStart(2, "0");
  let text: string;
  try { text = fs.readFileSync(path.join(dir, `bot-${day.getFullYear()}-${p(day.getMonth() + 1)}-${p(day.getDate())}.jsonl`), "utf8"); } catch { return []; }
  const out: { t: number; name: string; text: string }[] = [];
  for (const line of text.split("\n")) {
    if (!line) continue;
    try {
      const o = JSON.parse(line);
      if (typeof o?.t !== "number" || typeof o?.name !== "string") continue;
      out.push({ t: o.t, name: o.name, text: typeof o.text === "string" ? o.text : "" });
    } catch { /* a torn line */ }
  }
  return out.reverse();
}

/// Every action item in the meetings and notes, and the people in them.
/// `me`: the user's own names, so "Nikhil" in an attendee list isn't a person to list.
export function tasksAndPeople(library: LibraryEntry[], me: string[] = []): { tasks: any[]; people: any[] } {
  const mine = new Set(me.map(m => m.toLowerCase()).filter(m => m));
  const tasks: any[] = [];
  const people = new Map<string, { meetings: any[]; theirs: any[]; mine: any[] }>();
  for (const e of library) {
    if (e.kind !== "meetings" && e.kind !== "notes") continue;
    const md = e.file.slice(0, e.file.length - path.extname(e.file).length) + ".md";
    let text: string;
    try { text = fs.readFileSync(md, "utf8"); } catch { continue; }
    const meeting = { id: e.file, title: e.title, date: e.date };
    const items = actionItems(text).map(i => ({
      md, n: i.n, text: i.text, owner: i.owner, due: i.due, done: i.done, mine: isMe(i.owner), meeting,
    }));
    tasks.push(...items);
    const owners = items.filter(i => !i.mine).map(i => person(i.owner)).filter((o): o is string => o != null);
    const names = attendees(text);
    for (const o of owners) if (!names.some(n => n.toLowerCase() === o.toLowerCase())) names.push(o);
    for (const name of names) {
      const key = name.toLowerCase();
      if (mine.has(key)) continue;
      if (!people.has(key)) people.set(key, { meetings: [], theirs: [], mine: [] });
      const p = people.get(key)!;
      p.meetings.push({ ...meeting, name });
      for (const i of items) {
        if (i.done) continue;
        if (person(i.owner)?.toLowerCase() === key) p.theirs.push(i);
        else if (i.mine) p.mine.push(i);
      }
    }
  }
  const list = [...people].map(([key, p]) => {
    const first = p.meetings[0];
    return { name: first?.name ?? key, meetings: p.meetings, theirs: p.theirs, mine: p.mine, last: first?.date ?? "" };
  });
  return { tasks, people: list };
}
