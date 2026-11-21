import crypto from 'node:crypto';
import express from 'express';
import { STAFF } from './auth.js';
import { deviceAuth } from './pairing.js';
import { ForbiddenError } from './summaries.js';

const bad = (msg) => Object.assign(new Error(msg), { status: 400 });
const notFound = () => Object.assign(new Error('not found'), { status: 404 });
const taken = () => Object.assign(new Error('name taken'), { status: 409 });

const cleanName = (v) => { if (typeof v !== 'string' || !v.trim() || v.trim().length > 80) throw bad('bad name'); return v.trim(); };
const cleanDesc = (v) => { if (typeof v !== 'string' || v.length > 200) throw bad('bad description'); return v; };

// Latest summary-item date per project id, for a whole org.
const itemRows = (db, orgId) => db.prepare("SELECT user_id, date, items FROM summaries WHERE org_id = ? AND kind = 'day' ORDER BY date DESC").all(orgId);

const userNames = (db) => Object.fromEntries(db.prepare('SELECT id, name FROM users').all().map((u) => [u.id, u.name]));

// A project's items and meeting shares grouped by date, newest first.
function projectDays(db, orgId, p, names) {
  const byDate = {};
  const day = (d) => (byDate[d] ??= { date: d, meetings: [], items: [] });
  for (const s of itemRows(db, orgId))
    for (const i of JSON.parse(s.items)) if (i.project_id === p.id) day(s.date).items.push({ ...i, user_id: s.user_id, name: names[s.user_id] ?? null });
  for (const m of db.prepare('SELECT id, title, body, user_id, date FROM meeting_shares WHERE project_id = ? AND org_id = ? ORDER BY created_at').all(p.id, orgId))
    day(m.date).meetings.push({ id: m.id, title: m.title, body: m.body, user_id: m.user_id, name: names[m.user_id] ?? null });
  return Object.values(byDate).sort((a, b) => b.date.localeCompare(a.date));
}

export function projectRouter(db, anyMember) {
  const r = express.Router();
  const uid = () => crypto.randomUUID();
  const members = (pid) => db.prepare('SELECT pu.user_id, u.name FROM project_users pu JOIN users u ON u.id = pu.user_id WHERE pu.project_id = ? ORDER BY pu.added_at, pu.user_id').all(pid);
  const mine = (req) => db.prepare('SELECT * FROM projects WHERE id = ? AND org_id = ?').get(req.params.id, req.session.orgId) ?? (() => { throw notFound(); })();
  const writer = (req, p) => STAFF.includes(req.session.role) || !!db.prepare('SELECT 1 FROM project_users WHERE project_id = ? AND user_id = ?').get(p.id, req.session.userId);
  const mustWrite = (req) => { const p = mine(req); if (!writer(req, p)) throw new ForbiddenError(); return p; };
  const rename = (fn) => { try { return fn(); } catch (e) { throw /UNIQUE/.test(e.message) ? taken() : e; } };

  r.get('/projects', anyMember, (req, res) => {
    const { orgId } = req.session, last = {};
    for (const s of itemRows(db, orgId)) for (const i of JSON.parse(s.items)) if (i.project_id && !last[i.project_id]) last[i.project_id] = s.date;
    for (const m of db.prepare('SELECT project_id, MAX(date) d FROM meeting_shares WHERE org_id = ? GROUP BY project_id').all(orgId)) if (!(last[m.project_id] >= m.d)) last[m.project_id] = m.d;
    res.json(db.prepare('SELECT id, name, description FROM projects WHERE org_id = ? AND archived = 0').all(orgId)
      .map((p) => ({ ...p, archived: false, members: members(p.id), last_activity: last[p.id] ?? null }))
      .sort((a, b) => (b.last_activity ?? '').localeCompare(a.last_activity ?? '') || a.name.localeCompare(b.name)));
  });

  r.post('/projects', anyMember, (req, res) => {
    const name = cleanName(req.body?.name), description = req.body?.description === undefined ? '' : cleanDesc(req.body.description);
    const id = uid(), { orgId, userId } = req.session, now = Date.now();
    rename(() => db.transaction(() => {
      db.prepare('INSERT INTO projects (id, org_id, name, description, created_by, created_at) VALUES (?,?,?,?,?,?)').run(id, orgId, name, description, userId, now);
      db.prepare('INSERT INTO project_users VALUES (?,?,?)').run(id, userId, now);
    })());
    res.json({ id });
  });

  r.patch('/projects/:id', anyMember, (req, res) => {
    const p = mustWrite(req), b = req.body ?? {};
    const name = b.name === undefined ? p.name : cleanName(b.name);
    const description = b.description === undefined ? p.description : cleanDesc(b.description);
    if (b.archived !== undefined && typeof b.archived !== 'boolean') throw bad('bad archived');
    rename(() => db.prepare('UPDATE projects SET name = ?, description = ?, archived = ? WHERE id = ?').run(name, description, b.archived === undefined ? p.archived : +b.archived, p.id));
    res.json({ ok: true });
  });

  r.put('/projects/:id/members/:userId', anyMember, (req, res) => {
    const p = mustWrite(req);
    if (!db.prepare('SELECT 1 FROM memberships WHERE user_id = ? AND org_id = ?').get(req.params.userId, p.org_id)) throw bad('not an org member');
    db.prepare('INSERT OR IGNORE INTO project_users VALUES (?,?,?)').run(p.id, req.params.userId, Date.now());
    res.json({ ok: true });
  });

  r.delete('/projects/:id/members/:userId', anyMember, (req, res) => {
    const p = mustWrite(req);
    if (!db.prepare('SELECT 1 FROM memberships WHERE user_id = ? AND org_id = ?').get(req.params.userId, p.org_id)) throw bad('not an org member');
    db.prepare('DELETE FROM project_users WHERE project_id = ? AND user_id = ?').run(p.id, req.params.userId);
    res.json({ ok: true });
  });

  r.get('/projects/:id', anyMember, (req, res) => {
    const p = mine(req), { orgId } = req.session;
    const days = projectDays(db, orgId, p, userNames(db));
    res.json({
      project: { id: p.id, name: p.name, description: p.description, archived: !!p.archived, members: members(p.id), can_edit: writer(req, p) },
      days,
    });
  });

  r.get('/device/projects', deviceAuth(db), (req, res) => {
    const { userId, orgId } = req.device;
    res.json(db.prepare('SELECT p.id, p.name FROM projects p JOIN project_users pu ON pu.project_id = p.id WHERE pu.user_id = ? AND p.org_id = ? AND p.archived = 0 ORDER BY p.name').all(userId, orgId));
  });

  r.get('/device/projects/feed', deviceAuth(db), (req, res) => {
    const { userId, orgId } = req.device, n = Math.min(60, Math.max(1, parseInt(req.query.days, 10) || 14));
    const since = new Date(Date.now() - (n - 1) * 864e5).toISOString().slice(0, 10), names = userNames(db);
    res.json(db.prepare('SELECT p.id, p.name FROM projects p JOIN project_users pu ON pu.project_id = p.id WHERE pu.user_id = ? AND p.org_id = ? AND p.archived = 0 ORDER BY p.name').all(userId, orgId)
      .map((p) => ({ ...p, days: projectDays(db, orgId, p, names).filter((d) => d.date >= since)
        .map((d) => ({ date: d.date, meetings: d.meetings.map(({ title, body, name }) => ({ title, body, name })), items: d.items.map(({ what, section, name }) => ({ what, section, name })) })) })));
  });

  r.post('/projects/:id/meetings', deviceAuth(db), (req, res) => {
    const { userId, orgId } = req.device, { meeting_id, title, date, body } = req.body ?? {};
    const p = db.prepare('SELECT p.id FROM projects p JOIN project_users pu ON pu.project_id = p.id WHERE p.id = ? AND p.org_id = ? AND p.archived = 0 AND pu.user_id = ?').get(req.params.id, orgId, userId);
    if (!p) throw notFound();
    if (typeof meeting_id !== 'string' || !/^[A-Za-z0-9._-]{1,100}$/.test(meeting_id)) throw bad('bad meeting_id');
    if (typeof title !== 'string' || !title.trim() || title.length > 200) throw bad('bad title');
    if (typeof date !== 'string' || !/^\d{4}-\d{2}-\d{2}$/.test(date) || Number.isNaN(Date.parse(date))) throw bad('bad date');
    if (typeof body !== 'string' || body.length > 20000) throw bad('bad body');
    db.prepare(`INSERT INTO meeting_shares (id, org_id, project_id, user_id, meeting_id, title, date, body, created_at) VALUES (?,?,?,?,?,?,?,?,?)
      ON CONFLICT(project_id, user_id, meeting_id) DO UPDATE SET title = excluded.title, date = excluded.date, body = excluded.body, created_at = excluded.created_at`)
      .run(uid(), orgId, p.id, userId, meeting_id, title, date, body, Date.now());
    res.json({ ok: true });
  });

  return r;
}
