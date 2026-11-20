// Org model from the ERP: people, projects (teams) and their members. Hand edits always beat re-imports.
import crypto from 'node:crypto';

const bad = (msg) => Object.assign(new Error(msg), { status: 400 });
const text = (v, max = 200) => (typeof v === 'string' ? v.trim().slice(0, max) : '');
const name = (v) => { const s = text(v); if (!s) throw bad('bad name'); return s; };
const erpId = (v) => { if (!Number.isSafeInteger(v)) throw bad('bad erp_id'); return v; };
const list = (v, max) => { if (!Array.isArray(v) || v.length > max) throw bad('bad list'); return v; };
const obj = (v) => { if (!v || typeof v !== 'object') throw bad('bad entry'); return v; };

function clean(body) {
  obj(body);
  return {
    people: list(body.people, 2000).map((p) => (obj(p), {
      erp_id: erpId(p.erp_id), name: name(p.name), email: text(p.email).toLowerCase(), title: text(p.title),
      manager_erp_id: p.manager_erp_id == null ? null : erpId(p.manager_erp_id), note: text(p.note, 500),
    })),
    projects: list(body.projects, 1000).map((p) => (obj(p), {
      erp_id: erpId(p.erp_id), name: name(p.name), description: text(p.description, 500), active: p.active === false ? 0 : 1,
      members: list(p.members ?? [], 2000).map((m) => (obj(m), { erp_id: erpId(m.erp_id), role: m.lead === true ? 'lead' : 'member' })),
    })),
  };
}

export function importOrg(db, orgId, body) {
  const { people, projects } = clean(body);
  const userByEmail = db.prepare(`SELECT u.id FROM users u JOIN memberships m ON m.user_id = u.id AND m.org_id = ?
    WHERE lower(u.email) = ? AND ? <> '' LIMIT 1`);
  const upPerson = db.prepare(`INSERT INTO org_people (id, org_id, erp_id, name, email, title, manager_erp_id, note, user_id) VALUES (?,?,?,?,?,?,?,?,?)
    ON CONFLICT(org_id, erp_id) DO UPDATE SET name = excluded.name, email = excluded.email, title = excluded.title,
      manager_erp_id = excluded.manager_erp_id, note = excluded.note,
      user_id = CASE WHEN linked_by_hand THEN org_people.user_id ELSE excluded.user_id END`);
  const upProject = db.prepare(`INSERT INTO org_projects (id, org_id, erp_id, name, description, active) VALUES (?,?,?,?,?,?)
    ON CONFLICT(org_id, erp_id) DO UPDATE SET name = CASE WHEN name_by_hand THEN org_projects.name ELSE excluded.name END,
      description = excluded.description, active = excluded.active`);
  const personId = db.prepare('SELECT id FROM org_people WHERE org_id = ? AND erp_id = ?');
  const projectId = db.prepare('SELECT id FROM org_projects WHERE org_id = ? AND erp_id = ?');
  const upMember = db.prepare(`INSERT INTO project_members (project_id, person_id, role) VALUES (?,?,?)
    ON CONFLICT(project_id, person_id) DO UPDATE SET role = CASE WHEN role_by_hand THEN project_members.role ELSE excluded.role END`);
  // Dropped from the ERP project and never touched by hand: gone. Hand-edited rows (incl. removals) stay.
  const prune = db.prepare(`DELETE FROM project_members WHERE project_id = ? AND removed = 0 AND role_by_hand = 0
    AND person_id NOT IN (SELECT value FROM json_each(?))`);
  db.transaction(() => {
    for (const p of people)
      upPerson.run(crypto.randomUUID(), orgId, p.erp_id, p.name, p.email, p.title, p.manager_erp_id, p.note, userByEmail.get(orgId, p.email, p.email)?.id ?? null);
    for (const p of projects) {
      upProject.run(crypto.randomUUID(), orgId, p.erp_id, p.name, p.description, p.active);
      const pid = projectId.get(orgId, p.erp_id).id, kept = [];
      for (const m of p.members) {
        const person = personId.get(orgId, m.erp_id);
        if (!person) continue; // member not among the org's people: skip
        upMember.run(pid, person.id, m.role); kept.push(person.id);
      }
      prune.run(pid, JSON.stringify(kept));
    }
  })();
}

// Link a user to their unlinked person row by email (on join/login). Never overrides a hand link.
export const linkByEmail = (db, orgId, userId) => db.prepare(`UPDATE org_people SET user_id = ?
  WHERE org_id = ? AND user_id IS NULL AND linked_by_hand = 0 AND email <> '' AND email = (SELECT lower(email) FROM users WHERE id = ?)`).run(userId, orgId, userId);

export function orgView(db, orgId) {
  const people = db.prepare('SELECT id, erp_id, name, email, title, manager_erp_id, note, user_id FROM org_people WHERE org_id = ? ORDER BY name')
    .all(orgId).map((p) => ({ ...p, joined: p.user_id != null }));
  const members = db.prepare(`SELECT pm.person_id, p.name, pm.role, pm.removed, p.user_id FROM project_members pm
    JOIN org_people p ON p.id = pm.person_id WHERE pm.project_id = ? ORDER BY p.name`);
  const projects = db.prepare('SELECT id, erp_id, name, description, active, archived FROM org_projects WHERE org_id = ? ORDER BY name').all(orgId)
    .map((p) => ({ ...p, active: !!p.active, archived: !!p.archived,
      members: members.all(p.id).map(({ user_id, removed, ...m }) => ({ ...m, removed: !!removed, joined: user_id != null })) }));
  return { people, projects };
}

export function teamsFor(db, orgId, userId, role) {
  if (role === 'owner' || role === 'admin')
    return db.prepare('SELECT id, name FROM org_projects WHERE org_id = ? AND archived = 0 ORDER BY name').all(orgId);
  return db.prepare(`SELECT pr.id, pr.name FROM org_projects pr JOIN project_members pm ON pm.project_id = pr.id
    JOIN org_people p ON p.id = pm.person_id
    WHERE pr.org_id = ? AND pr.archived = 0 AND p.org_id = ? AND p.user_id = ? AND pm.role = 'lead' AND pm.removed = 0 ORDER BY pr.name`).all(orgId, orgId, userId);
}

export const teamMemberUserIds = (db, projectId) => db.prepare(`SELECT p.user_id FROM project_members pm JOIN org_people p ON p.id = pm.person_id
  WHERE pm.project_id = ? AND pm.removed = 0 AND p.user_id IS NOT NULL`).all(projectId).map((r) => r.user_id);
