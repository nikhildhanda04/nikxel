import * as fs from "fs";
import * as path from "path";

/// Port of NoteName.swift. A meeting or notes summary is saved as
/// "2026-11-24-153012.md" (+ .html, .transcript.txt, …). Its page offers a
/// title Nikxel suggests; saving one renames every file of that summary to
/// "Q3 Budget Review 2026-11-24-153012.*". Anything that dates a summary by its
/// file name reads `stamp`, which finds the timestamp at the end.

/// Still named by its timestamp alone.
export function isUnnamed(stem: string): boolean {
  return /^\d{4}-\d{2}-\d{2}-\d{6}$/.test(stem);
}

/// The "yyyy-MM-dd-HHmmss" a summary is dated by: the whole stem, or its end
/// once named ("<name> <stamp>"). Older "yyyy-MM-dd-HHmm" stems too.
export function stamp(stem: string): string {
  return /\d{4}-\d{2}-\d{2}-\d{4}(\d{2})?$/.exec(stem)?.[0] ?? stem;
}

/// The agent's or the user's answer made safe as a file name: first line,
/// no path or quote characters, at most 60 characters.
export function clean(raw: string): string {
  const line = raw.split(/\r?\n/)[0] ?? "";
  const kept = line.replace(/[\/\\:*?"<>|`#\x00-\x1f\x7f]/g, "").replace(/\s+/g, " ").replace(/^[ .'-]+|[ .'-]+$/g, "");
  return Array.from(kept).slice(0, 60).join("").trim();
}

export function prompt(summary: string): string {
  return "Suggest a file name for this summary: 3 to 6 words, Title Case, naming what it was "
    + "about (the client, project or main decision). No date, no quotes, no file extension. "
    + "Reply with the name only.\n\n" + summary.slice(0, 6000);
}

/// Renames every "<stem>.*" beside `page`, and its edit history in `editsDir`,
/// to "<name> <stem>.*". Returns the renamed page.
export function rename(page: string, raw: string, editsDir: string): string {
  const name = clean(raw), dir = path.dirname(page), ext = path.extname(page);
  const stem = path.basename(page, ext), newStem = `${name} ${stem}`;
  if (!isUnnamed(stem)) throw new Error("This summary already has a name.");
  if (!/[\p{L}\p{N}]/u.test(name)) throw new Error("Give it a name with at least one letter or number.");
  const moves = fs.readdirSync(dir).filter(f => f.startsWith(stem + "."))
    .map(f => [path.join(dir, f), path.join(dir, newStem + f.slice(stem.length))] as const);
  if (moves.some(([, to]) => fs.existsSync(to))) throw new Error("A summary with that name already exists.");
  for (const [from, to] of moves) fs.renameSync(from, to);
  try { fs.renameSync(path.join(editsDir, stem), path.join(editsDir, newStem)); } catch { /* no edits yet */ }
  return path.join(dir, newStem + ext);
}
