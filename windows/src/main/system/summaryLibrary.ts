import * as fs from "fs";
import * as path from "path";
import { documentsRoot } from "../core/paths";
import * as NoteName from "./noteName";

/// Port of SummaryLibrary.swift.
///
/// Every summary under ~/Documents/nikxel, for the dashboard's Library: one
/// entry per stem (a meeting's .md, .html, .transcript.txt… are one entry),
/// newest first. Reads directory listings and the first lines of each .md only,
/// so it's cheap enough to run every time the window comes forward.

export interface LibraryEntry { kind: string; title: string; date: string; snippet: string; file: string }

export function libraryRoot(): string { return path.join(documentsRoot(), "nikxel"); }

export const KINDS = ["meetings", "notes", "daily", "weekly"];

/// The file each summary opens as, in order of preference.
const OPENS = ["html", "pdf", "docx", "md"];

export function entryDict(e: LibraryEntry): { id: string; kind: string; title: string; date: string; snippet: string; ext: string } {
  return { id: e.file, kind: e.kind, title: e.title, date: e.date, snippet: e.snippet, ext: path.extname(e.file).slice(1) };
}

export function scan(root: string = libraryRoot()): LibraryEntry[] {
  return KINDS.flatMap(k => scanKind(k, path.join(root, k))).sort((a, b) => a.date < b.date ? 1 : a.date > b.date ? -1 : 0);
}

export function scanKind(kind: string, dir: string): LibraryEntry[] {
  let names: string[];
  try { names = fs.readdirSync(dir); } catch { return []; }
  const byStem = new Map<string, Set<string>>();
  for (const name of names) {
    if (name.startsWith(".")) continue;
    const ext = path.extname(name).slice(1), stem = path.basename(name, path.extname(name));
    // "x.client.html", "x.transcript.txt", "x.sent.json" belong to x and don't open on their own.
    if (!OPENS.includes(ext) || stem.includes(".")) continue;
    if (!byStem.has(stem)) byStem.set(stem, new Set());
    byStem.get(stem)!.add(ext);
  }
  const out: LibraryEntry[] = [];
  for (const [stem, exts] of byStem) {
    const ext = OPENS.find(e => exts.has(e));
    if (!ext) continue;
    const file = path.join(dir, `${stem}.${ext}`);
    const md = exts.has("md") ? head(path.join(dir, `${stem}.md`)) : "";
    const { heading, snippet } = parse(md);
    const stamp = NoteName.stamp(stem);
    const named = stamp !== stem ? stem.slice(0, stem.length - stamp.length).trim() : "";
    const title = named ? named
      : heading ? heading
      : ext === "html" ? htmlTitle(file) ?? stem : stem;
    out.push({ kind, title, date: entryDate(stem, file), snippet, file });
  }
  return out;
}

/// The first `# ` heading and the first line of prose under it.
export function parse(md: string): { heading: string; snippet: string } {
  let heading = "", snippet = "";
  for (const raw of md.split(/\r\n|\r|\n/)) {
    const line = raw.trim();
    if (!heading && line.startsWith("# ")) { heading = line.slice(2); continue; }
    if (!line || line.startsWith("#") || line.startsWith("|") || line.startsWith("---") || line.startsWith("<")) continue;
    snippet = line.replace(/^[-*]\s+|\*\*|__/g, "");
    break;
  }
  return { heading, snippet: Array.from(snippet).slice(0, 160).join("") };
}

/// "yyyy-MM-dd HH:mm" from the stem's timestamp ("…2026-11-24-170838" or a
/// day page's "2026-11-24"), else the file's modified time. Sorts as text.
export function entryDate(stem: string, file: string): string {
  const stamp = NoteName.stamp(stem);
  if (/^\d{4}-\d{2}-\d{2}-\d{4}/.test(stamp)) return `${stamp.slice(0, 10)} ${stamp.slice(11, 13)}:${stamp.slice(13, 15)}`;
  if (/^\d{4}-\d{2}-\d{2}$/.test(stem)) return stem + " 00:00";
  let mod = new Date(0);
  try { mod = fs.statSync(file).mtime; } catch { /* epoch */ }
  const p = (n: number) => String(n).padStart(2, "0");
  return `${mod.getFullYear()}-${p(mod.getMonth() + 1)}-${p(mod.getDate())} ${p(mod.getHours())}:${p(mod.getMinutes())}`;
}

function head(file: string): string {
  let fd: number;
  try { fd = fs.openSync(file, "r"); } catch { return ""; }
  try {
    const buf = Buffer.alloc(4096);
    return buf.toString("utf8", 0, fs.readSync(fd, buf, 0, 4096, 0));
  } catch { return ""; } finally { fs.closeSync(fd); }
}

function htmlTitle(file: string): string | null {
  const m = /(?<=<title>)[^<]+/.exec(head(file));
  return m ? m[0].trim() : null;
}
