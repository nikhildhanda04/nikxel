import * as fs from "fs";
import { readText, resourcePath } from "../core/paths";
import { Settings } from "../core/settings";

/// What each update added, from WHATSNEW.md (copied by copy-static.js as
/// resources/whatsnew.md): the Nikxel window's What's new section, and the tour
/// that runs once after an update. Mirrors src/WhatsNew.swift.
export interface Step { section: string; title: string; text: string }
export interface Item { title: string; body: string; tour: Step[] }
export interface Release { id: string; items: Item[] }

/// `## id` starts an update, `### title` a change, and each `tour: section | title | text`
/// line under a change is a step of its tour (title and text default to the change's);
/// the other lines are its paragraph. Text before the first update and HTML comments are skipped.
export function parse(md: string): Release[] {
  const out: { id: string; items: { title: string; lines: string[]; tour: string[][] }[] }[] = [];
  let comment = false;
  for (const l of md.split(/\r?\n/)) {
    const line = l.trim();
    if (comment) { if (line.includes("-->")) comment = false; continue; }
    if (line.startsWith("<!--")) { comment = !line.includes("-->"); continue; }
    if (line.startsWith("## ")) out.push({ id: line.slice(3).trim(), items: [] });
    else if (line.startsWith("### ") && out.length) out[out.length - 1].items.push({ title: line.slice(4).trim(), lines: [], tour: [] });
    else {
      const it = out[out.length - 1]?.items.slice(-1)[0];
      if (!it) continue;
      if (/^tour:/i.test(line)) {
        const parts = line.slice(5).split("|").map(p => p.trim());
        it.tour.push(parts.length > 3 ? [parts[0], parts[1], parts.slice(2).join("|")] : parts);
      } else it.lines.push(line);
    }
  }
  return out.map(r => ({
    id: r.id,
    items: r.items.map(it => {
      // Lines become paragraphs at blank lines.
      const body = it.lines.join("\n").split(/\n{2,}/).map(p => p.split("\n").filter(Boolean).join(" ")).filter(Boolean).join("\n\n");
      const tour = it.tour.filter(p => p[0]).map(p => ({ section: p[0], title: p[1] || it.title, text: p[2] || body }));
      return { title: it.title, body, tour };
    }),
  }));
}

/// The updates someone hasn't seen yet, newest first: those above `seen`.
/// Never seen anything: only the newest, not the whole history.
export function unseen(releases: Release[], seen: string | undefined): string[] {
  if (!releases.length) return [];
  // Never seen anything: the newest day's updates ("2026-11-27", "2026-11-27.2"…), not the whole history.
  if (!seen) { const day = releases[0].id.slice(0, 10); return releases.filter((r, i) => releases.slice(0, i + 1).every(x => x.id.slice(0, 10) === day)).map(r => r.id); }
  const i = releases.findIndex(r => r.id === seen);
  return releases.slice(0, i < 0 ? releases.length : i).map(r => r.id);
}

export function releases(): Release[] {
  const f = resourcePath("whatsnew.md");
  return fs.existsSync(f) ? parse(readText(f) ?? "") : [];
}

/// Unseen updates, for the window and the launch card. [] for someone who
/// hasn't had the first-run tour yet: everything is new to them.
export function pending(): string[] {
  return Settings.dashboardTourDone ? unseen(releases(), Settings.whatsNewSeen) : [];
}

export function markSeen(): void {
  const id = releases()[0]?.id;
  if (id) Settings.whatsNewSeen = id;
}

export function forPage(): Release[] { return releases().slice(0, 12); }
