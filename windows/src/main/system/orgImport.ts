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
    "project members and leads, and short AI-written notes. Task names stay on this PC.";
}

export function prompt(s: OrgSnapshot): string {
  let out = "You are mapping a company's ERP into an org chart. For each project, write a one-line description " +
    "(at most 15 words) of what it is, from its name and recent task names. For each person, write a short " +
    "\"works on\" note (at most 15 words) from their title and projects. Use only what is given; never invent " +
    "clients, numbers or dates. Reply with ONLY this JSON, keys being the ids in brackets:\n" +
    "{\"projects\":{\"<id>\":\"<description>\"},\"people\":{\"<id>\":\"<note>\"}}\n\nPROJECTS\n";
  const onProjects = new Map<number, string[]>();
  for (const p of s.projects) {
    out += `- [${p.id}] ${p.name}` + (p.taskNames.length ? " — recent tasks: " + p.taskNames.join("; ") : "") + "\n";
    for (const m of members(p, s.people)) onProjects.set(m.person.id, [...(onProjects.get(m.person.id) ?? []), p.name]);
  }
  out += "\nPEOPLE\n";
  for (const e of s.people) {
    const on = onProjects.get(e.id);
    out += `- [${e.id}] ${e.name}` + (e.title ? ` — ${e.title}` : "") + (on ? " — on: " + on.join(", ") : "") + "\n";
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
