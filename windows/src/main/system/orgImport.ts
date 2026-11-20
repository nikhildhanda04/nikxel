/// "Build org from ERP…": snapshot -> one AI prompt -> import body -> (dialog) -> POST /api/org/import.
/// DATA BOUNDARY: only the body below is sent: people {erp_id,name,email,title,manager_erp_id,note},
/// projects {erp_id,name,description,active,members:[{erp_id,lead}]}. Port of OrgImport.swift.

export interface OrgPerson { id: number; name: string; email: string; title: string; managerID: number | null; userID: number | null }
/// `userIDs`: res.users ids assigned to the project's tasks in the window; `active`: Odoo's flag.
export interface OrgProject { id: number; name: string; managerUserID: number | null; active: boolean; userIDs: number[]; taskNames: string[] }
/// What ERP.orgSnapshot() reads. Task names are for the AI prompt only and never leave the PC.
export interface OrgSnapshot { people: OrgPerson[]; projects: OrgProject[] }
/// The AI's notes, keyed by erp_id.
export interface OrgAI { projects: Record<number, string>; people: Record<number, string> }

export interface ImportBody {
  people: { erp_id: number; name: string; email: string; title: string; manager_erp_id: number | null; note: string }[];
  projects: { erp_id: number; name: string; description: string; active: boolean; members: { erp_id: number; lead: boolean }[] }[];
}

/// Members are employees whose user is on the project's tasks; the project manager is the lead.
function members(p: OrgProject, people: OrgPerson[]): { person: OrgPerson; lead: boolean }[] {
  const on = new Set(p.userIDs);
  return people.filter(e => e.userID != null && (e.userID === p.managerUserID || on.has(e.userID)))
    .map(e => ({ person: e, lead: e.userID === p.managerUserID }));
}

export function buildImportBody(s: OrgSnapshot, ai: OrgAI): ImportBody {
  const people = s.people.filter(p => p.name).slice(0, 2000);
  return {
    people: people.map(p => ({ erp_id: p.id, name: p.name, email: p.email, title: p.title, manager_erp_id: p.managerID, note: ai.people[p.id] ?? "" })),
    projects: s.projects.filter(p => p.name).slice(0, 1000).map(p => ({
      erp_id: p.id, name: p.name, description: ai.projects[p.id] ?? "", active: p.active && p.taskNames.length > 0,
      members: members(p, people).map(m => ({ erp_id: m.person.id, lead: m.lead })),
    })),
  };
}

/// The confirmation dialog's text: counts and exactly which fields go.
export function summary(body: ImportBody): string {
  const active = body.projects.filter(p => p.active).length;
  return `${body.people.length} people and ${body.projects.length} projects (${active} active) — names, work emails, job titles, managers, ` +
    "project members and leads, plus project descriptions and people notes that AI wrote from task names " +
    "(the task names themselves are not sent).";
}

/// Odoo search_read rows -> snapshot. Employees unreadable -> no people (projects still go);
/// projects or tasks unreadable -> null (nothing to send). Keeps up to 15 task names per project.
export function snapshot(employees: unknown, projects: unknown, tasks: unknown): OrgSnapshot | null {
  if (!Array.isArray(projects) || !Array.isArray(tasks)) return null;
  const m2o = (v: unknown) => (Array.isArray(v) && typeof v[0] === "number" ? v[0] : null); // [id, "Name"] or false
  const str = (v: unknown) => (typeof v === "string" ? v : "");
  const users = new Map<number, Set<number>>(), names = new Map<number, string[]>();
  for (const t of tasks as Record<string, unknown>[]) {
    const p = m2o(t?.project_id);
    if (p == null) continue;
    if (!users.has(p)) { users.set(p, new Set()); names.set(p, []); }
    for (const u of Array.isArray(t.user_ids) ? t.user_ids : []) if (typeof u === "number") users.get(p)!.add(u);
    if (names.get(p)!.length < 15) names.get(p)!.push(str(t.name));
  }
  const rows = (a: unknown) => (Array.isArray(a) ? a : []).filter((r): r is Record<string, unknown> => !!r && typeof (r as any).id === "number");
  return {
    people: rows(employees).map(r => ({ id: r.id as number, name: str(r.name), email: str(r.work_email), title: str(r.job_title), managerID: m2o(r.parent_id), userID: m2o(r.user_id) })),
    projects: rows(projects).map(r => ({
      id: r.id as number, name: str(r.name), managerUserID: m2o(r.user_id), active: r.active !== false,
      userIDs: [...(users.get(r.id as number) ?? [])].sort((x, y) => x - y), taskNames: names.get(r.id as number) ?? [],
    })),
  };
}

/// Bounded: active projects only (at most 200), task names cut to 80 chars, people only when on
/// one of those projects, and the whole prompt at most 60k chars (lines past that are dropped).
export function prompt(s: OrgSnapshot): string {
  let out = "You are mapping a company's ERP into an org chart. For each project, write a one-line description " +
    "(at most 15 words) of what it is, from its name and recent task names. For each person, write a short " +
    "\"works on\" note (at most 15 words) from their title and projects. Use only what is given; never invent " +
    "clients, numbers or dates. Reply with ONLY this JSON, keys being the ids in brackets:\n" +
    "{\"projects\":{\"<id>\":\"<description>\"},\"people\":{\"<id>\":\"<note>\"}}\n\nPROJECTS\n";
  const add = (line: string) => { if (out.length + line.length <= 60000) out += line; };
  const onProjects = new Map<number, string[]>();
  for (const p of s.projects.filter(p => p.active && p.taskNames.length).slice(0, 200)) {
    add(`- [${p.id}] ${p.name} — recent tasks: ` + p.taskNames.map(t => t.slice(0, 80)).join("; ") + "\n");
    for (const m of members(p, s.people)) onProjects.set(m.person.id, [...(onProjects.get(m.person.id) ?? []), p.name]);
  }
  add("\nPEOPLE\n");
  for (const e of s.people) {
    const on = onProjects.get(e.id);
    if (on) add(`- [${e.id}] ${e.name}` + (e.title ? ` — ${e.title}` : "") + " — on: " + on.join(", ") + "\n");
  }
  return out;
}

/// The AI reply's JSON object (fenced or not, chatter around it ignored); empty maps when it doesn't parse.
export function parseAI(text: string): OrgAI {
  const a = text.indexOf("{"), b = text.lastIndexOf("}");
  let obj: any = null;
  if (a >= 0 && a < b) try { obj = JSON.parse(text.slice(a, b + 1)); } catch { /* garbage */ }
  const map = (v: unknown): Record<number, string> => {
    const out: Record<number, string> = {};
    if (v && typeof v === "object" && !Array.isArray(v))
      for (const [k, s] of Object.entries(v)) if (/^-?\d+$/.test(k) && typeof s === "string") out[Number(k)] = s;
    return out;
  };
  return { projects: map(obj?.projects), people: map(obj?.people) };
}
