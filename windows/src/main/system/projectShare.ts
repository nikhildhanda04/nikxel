import * as path from "path";
import * as NoteName from "./noteName";
import { cblog } from "../core/diag";
import { nikxelPath, readText, writeAtomic } from "../core/paths";
import { CloudSync } from "./cloudSync";

/// "Share to project" on a meeting page (pageShare /projects and /share-project).
/// Sends the minutes beside the page (<stem>.md, minus its Client Summary) to one
/// of the user's dashboard projects. Port of ProjectShare.swift.

/// What a share of the minutes page `file` sends: the stem is the meeting id,
/// the "# " line the title, the stem's first 10 characters the date.
/// null when the page isn't saved meeting minutes.
export function meeting(file: string): { id: string; title: string; date: string; body: string } | null {
  if (path.basename(path.dirname(file)) !== "meetings") return null;
  const md = readText(file.replace(/\.html$/i, ".md"));
  if (md == null) return null;
  const stem = path.basename(file).replace(/\.html$/i, "");
  const title = (md.split("\n").find((l) => l.startsWith("# ")) ?? "").slice(2).trim();
  return { id: stem, title: (title || "Meeting").slice(0, 200), date: NoteName.stamp(stem).slice(0, 10), body: CloudSync.meetingShareBody(md) };
}

/// `project` null: {paired, projects, body, suggested, why, sent}: body is exactly what Push sends,
/// suggested the project Nikxel thinks it's from, sent where it last went. Otherwise sends to that project.
export async function handle(project: string | null, file: string): Promise<Record<string, unknown>> {
  const m = meeting(file);
  if (!m) return { error: "Only saved meeting minutes can be shared to a project." };
  const sentFile = file.replace(/\.html$/i, ".shared.json");
  if (project === null) {
    const projects = await CloudSync.projects();
    let sent: Record<string, unknown> | null = null;
    try { sent = JSON.parse(readText(sentFile) ?? "null"); } catch { sent = null; }
    const pick = suggest(projects, m.title, m.body, loadPicks());
    return { paired: CloudSync.token() !== null, projects, body: m.body,
      suggested: (sent?.project as string | undefined) ?? pick?.id ?? null, why: sent ? "" : pick?.why ?? "", sent };
  }
  if (!CloudSync.token()) return { error: "Connect Nikxel to the dashboard first" };
  if (!project) return { error: "Pick a project." };
  const ok = await CloudSync.shareMeeting(project, m.id, m.title, m.date, m.body);
  cblog(`ProjectShare: ${m.id} → ${project}: ${ok ? "sent" : "failed"}`);
  if (!ok) return { error: "Couldn't push it. Check you're still on that project, then try again." };
  // Where it went (this page shows it), and what to suggest next time.
  const name = (await CloudSync.projects()).find(p => p.id === project)?.name ?? "";
  const sent = { project, name, at: Date.now() / 1000 };
  try { writeAtomic(sentFile, JSON.stringify(sent)); } catch { /* the push still went */ }
  const picks = loadPicks(); picks.last = project; picks.titles[seriesKey(m.title)] = project;
  try { writeAtomic(picksFile.path, JSON.stringify(picks)); } catch { /* next time just won't remember */ }
  return { ok: true, sent };
}

// MARK: - Which project a meeting is from

/// What the user picked before: the last project, and one per meeting title (a weekly call goes
/// where it went last week). ~/.nikxel/project-picks.json; settable so checks can move it.
export interface Picks { last?: string; titles: Record<string, string> }
export const picksFile = { path: nikxelPath("project-picks.json") };
export function loadPicks(): Picks {
  try { const p = JSON.parse(readText(picksFile.path) ?? "{}"); return { last: p.last, titles: p.titles ?? {} }; } catch { return { titles: {} }; }
}

/// A meeting title without its dates and numbers, so "Weekly sync 12 Nov" and "Weekly sync 19 Nov" match.
export function seriesKey(title: string): string {
  return title.toLowerCase().replace(/[^a-z]+/g, " ").replace(/\b(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\b/g, " ")
    .split(" ").filter(Boolean).join(" ");
}

/// The project these minutes are most likely about, and why: where a meeting with this title went
/// before (the user's own pick wins); else the one named most in the title and minutes (the title
/// counts three times); else the last project used. null: no idea, the user picks.
/// ponytail: name matching, not a model; ask the agent if suggestions miss too often.
export function suggest(projects: { id: string; name: string }[], title: string, body: string, picks: Picks): { id: string; why: string } | null {
  const ids = new Set(projects.map(p => p.id));
  const series = picks.titles[seriesKey(title)];
  if (series && ids.has(series)) return { id: series, why: "Where this meeting went last time." };
  const norm = (x: string) => x.toLowerCase().replace(/[^\p{L}\p{N}]+/gu, " ").trim();
  const text = " " + norm([title, title, title, body].join(" ")) + " ";
  const count = (w: string) => text.split(" " + w + " ").length - 1;
  const common = new Set(["project", "projects", "app", "team", "the", "and", "for", "with", "new", "client", "meeting", "website", "dashboard"]);
  const scored = projects.map(p => {
    const name = norm(p.name), words = name.split(" ").filter(w => w.length >= 4 && !common.has(w));
    // Each distinctive word it's said, plus a bonus when a two-word-or-longer name is said whole.
    return { p, n: words.reduce((a, w) => a + count(w), 0) + (name.includes(" ") ? count(name) * 2 : 0) };
  });
  const best = Math.max(0, ...scored.map(x => x.n));
  const top = scored.filter(x => x.n === best);
  if (best > 0 && top.length === 1) return { id: top[0].p.id, why: "It’s named in these minutes." };
  if (picks.last && ids.has(picks.last)) return { id: picks.last, why: "The project you used last." };
  return null;
}
