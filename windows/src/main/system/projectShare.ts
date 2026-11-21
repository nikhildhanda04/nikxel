import * as path from "path";
import { cblog } from "../core/diag";
import { readText } from "../core/paths";
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
  return { id: stem, title: (title || "Meeting").slice(0, 200), date: stem.slice(0, 10), body: CloudSync.meetingShareBody(md) };
}

/// `project` null: {paired, projects, body}, body being exactly what Send would send.
/// Otherwise sends to that project.
export async function handle(project: string | null, file: string): Promise<Record<string, unknown>> {
  const m = meeting(file);
  if (!m) return { error: "Only saved meeting minutes can be shared to a project." };
  if (project === null) return { paired: CloudSync.token() !== null, projects: await CloudSync.projects(), body: m.body };
  if (!CloudSync.token()) return { error: "Connect Nikxel to the dashboard first" };
  if (!project) return { error: "Pick a project." };
  const ok = await CloudSync.shareMeeting(project, m.id, m.title, m.date, m.body);
  cblog(`ProjectShare: ${m.id} → ${project}: ${ok ? "sent" : "failed"}`);
  return ok ? { ok: true } : { error: "Couldn't share it. Check you're still on that project, then try again." };
}
