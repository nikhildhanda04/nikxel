import crypto from 'node:crypto';
import express from 'express';
import { readSession, issueSession, liveSession, requireRole, verifyGoogle } from './auth.js';
import { redeemPairingCode, createPairingCode, deviceAuth } from './pairing.js';
import { cleanDay, ForbiddenError } from './summaries.js';
import { importOrg, orgView, teamsFor, teamMemberUserIds } from './org.js';

const uid = () => crypto.randomUUID();
const bad = (msg) => Object.assign(new Error(msg), { status: 400 });
const notFound = () => Object.assign(new Error('not found'), { status: 404 });
const str = (v) => typeof v === 'string' && v.trim() !== '';

async function defaultExchange(code) {
  const r = await fetch('https://oauth2.googleapis.com/token', {
    method: 'POST', headers: { 'content-type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({ code, client_id: process.env.GOOGLE_CLIENT_ID, client_secret: process.env.GOOGLE_CLIENT_SECRET, redirect_uri: process.env.GOOGLE_REDIRECT_URI, grant_type: 'authorization_code' }),
  });
  if (!r.ok) throw bad('google exchange failed');
  return r.json();
}

export function buildRouter(db, { exchange = defaultExchange, verifier } = {}) {
  const r = express.Router();
  const secret = () => process.env.SESSION_SECRET;
  const session = (req, res, next) => {
    const s = readSession(req, secret());
    if (!s) return res.status(401).json({ error: 'unauthenticated' });
    req.session = liveSession(db, s); next();
  };
  const membership = (userId) => db.prepare('SELECT org_id, role FROM memberships WHERE user_id = ?').get(userId);
  const STATE = 'nikxel_oauth_state';
  r.get('/auth/google', (req, res) => {
    const state = crypto.randomBytes(16).toString('hex');
    res.cookie(STATE, state, { httpOnly: true, sameSite: 'lax', secure: true, path: '/api/auth/google', maxAge: 10 * 60 * 1000 });
    const q = new URLSearchParams({ state, client_id: process.env.GOOGLE_CLIENT_ID, redirect_uri: process.env.GOOGLE_REDIRECT_URI, response_type: 'code', scope: 'openid email profile' });
    res.redirect('https://accounts.google.com/o/oauth2/v2/auth?' + q);
  });

  r.get('/auth/google/callback', async (req, res) => {
    const raw = (req.headers.cookie || '').split(/;\s*/).find((c) => c.startsWith(STATE + '='));
    const want = raw?.slice(STATE.length + 1);
    res.clearCookie(STATE, { path: '/api/auth/google' });
    if (!want || req.query.state !== want) return res.status(401).json({ error: 'bad state' });
    if (!str(req.query.code)) throw bad('missing code');
    const { id_token } = await exchange(req.query.code);
    let g;
    try { g = await verifyGoogle(id_token, process.env.GOOGLE_CLIENT_ID, verifier); }
    catch { return res.status(401).json({ error: 'google verification failed' }); }
    db.prepare(`INSERT INTO users (id, google_sub, email, name, created_at) VALUES (?,?,?,?,?)
      ON CONFLICT(google_sub) DO UPDATE SET email = excluded.email, name = excluded.name`).run(uid(), g.sub, g.email, g.name ?? null, Date.now());
    const user = db.prepare('SELECT id FROM users WHERE google_sub = ?').get(g.sub);
    const m = membership(user.id);
    issueSession(res, { userId: user.id, orgId: m?.org_id ?? null, role: m?.role ?? null }, secret());
    res.redirect(m ? '/' : '/onboarding');
  });

  r.get('/me', session, (req, res) => {
    const u = db.prepare('SELECT name, email FROM users WHERE id = ?').get(req.session.userId);
    res.json({ userId: req.session.userId, orgId: req.session.orgId, role: req.session.role, name: u?.name ?? u?.email ?? null });
  });

  // Dev only: impossible unless DEV_LOGIN=1 is set in the environment.
  r.post('/dev/login', (req, res) => {
    if (process.env.DEV_LOGIN !== '1') return res.status(404).json({ error: 'not found' });
    const u = str(req.body?.userId) && db.prepare('SELECT id FROM users WHERE id = ?').get(req.body.userId);
    if (!u) return res.status(404).json({ error: 'no such user' });
    const m = membership(u.id);
    issueSession(res, { userId: u.id, orgId: m?.org_id ?? null, role: m?.role ?? null }, secret());
    res.json({ ok: true });
  });

  r.post('/orgs', session, (req, res) => {
    if (!str(req.body?.name)) throw bad('name required');
    if (membership(req.session.userId)) return res.status(409).json({ error: 'already in an org' });
    const orgId = uid();
    db.transaction(() => {
      db.prepare('INSERT INTO orgs VALUES (?,?,?,?)').run(orgId, req.body.name.trim(), req.session.userId, Date.now());
      db.prepare('INSERT INTO memberships VALUES (?,?,?)').run(req.session.userId, orgId, 'owner');
    })();
    issueSession(res, { userId: req.session.userId, orgId, role: 'owner' }, secret());
    res.json({ id: orgId });
  });

  r.post('/orgs/join', session, (req, res) => {
    if (!str(req.body?.token)) throw bad('token required');
    if (membership(req.session.userId)) return res.status(409).json({ error: 'already in an org' });
    const inv = db.transaction(() => {
      const i = db.prepare('SELECT * FROM invites WHERE token = ? AND accepted_by IS NULL').get(req.body.token);
      if (!i) return null;
      db.prepare('UPDATE invites SET accepted_by = ? WHERE id = ?').run(req.session.userId, i.id);
      db.prepare('INSERT INTO memberships VALUES (?,?,?)').run(req.session.userId, i.org_id, i.role);
      return i;
    })();
    if (!inv) return res.status(404).json({ error: 'invalid invite' });
    issueSession(res, { userId: req.session.userId, orgId: inv.org_id, role: inv.role }, secret());
    res.json({ orgId: inv.org_id, role: inv.role });
  });

  r.post('/invites', requireRole(db, 'owner', 'admin'), (req, res) => {
    const role = req.body?.role ?? 'member';
    if (!['member', 'admin'].includes(role)) throw bad('bad role');
    const token = crypto.randomBytes(24).toString('hex');
    db.prepare('INSERT INTO invites (id, org_id, token, role, created_at) VALUES (?,?,?,?,?)').run(uid(), req.session.orgId, token, role, Date.now());
    res.json({ token, role });
  });

  r.patch('/members/:userId', requireRole(db, 'owner', 'admin'), (req, res) => {
    const role = req.body?.role;
    if (!['admin', 'member'].includes(role)) throw bad('bad role');
    const t = db.prepare('SELECT role FROM memberships WHERE user_id = ? AND org_id = ?').get(req.params.userId, req.session.orgId);
    if (!t) throw notFound();
    if (t.role === 'owner') throw new ForbiddenError('owner role is fixed');
    db.prepare('UPDATE memberships SET role = ? WHERE user_id = ? AND org_id = ?').run(role, req.params.userId, req.session.orgId);
    res.json({ user_id: req.params.userId, role });
  });

  r.post('/auth/logout', (req, res) => {
    res.clearCookie('nikxel_session', { httpOnly: true, sameSite: 'lax', secure: true, path: '/' });
    res.json({ ok: true });
  });

  r.get('/members', requireRole(db, 'owner', 'admin'), (req, res) => {
    res.json(db.prepare(`SELECT m.user_id, m.role, u.email, u.name FROM memberships m JOIN users u ON u.id = m.user_id WHERE m.org_id = ?`).all(req.session.orgId));
  });

  r.get('/pairing-code', session, (req, res) => {
    if (!req.session.orgId) throw new ForbiddenError('join an org first');
    res.json({ code: createPairingCode(db, req.session.userId, req.session.orgId) });
  });

  // ponytail: in-memory per-IP limiter (resets on restart, per-process); move to shared store if scaled out.
  const hits = new Map();
  const pairLimit = (req, res, next) => {
    const now = Date.now(), k = req.ip;
    let h = hits.get(k);
    if (!h || h.reset <= now) hits.set(k, h = { n: 0, reset: now + 60_000 });
    if (++h.n > 10) return res.status(429).json({ error: 'too many attempts' });
    next();
  };
  r.post('/pair', pairLimit, (req, res) => {
    const out = str(req.body?.code) && redeemPairingCode(db, req.body.code);
    if (!out) return res.status(400).json({ error: 'invalid or expired code' });
    res.json({ deviceToken: out.deviceToken });
  });

  r.post('/summaries', deviceAuth(db), (req, res) => {
    if (req.body?.kind !== 'day') throw bad('bad summary');
    const { date, headline, items } = cleanDay(req.body);
    const { userId, orgId } = req.device; // never from the body
    db.prepare(`INSERT INTO summaries VALUES (?,?,?,'day',?,?,?,'admin','sent',?)
      ON CONFLICT(user_id, org_id, kind, date) DO UPDATE SET items = excluded.items, notes = excluded.notes, created_at = excluded.created_at`)
      .run(uid(), userId, orgId, date, JSON.stringify(items), headline, Date.now());
    res.json({ ok: true });
  });

  r.get('/summaries/mine', session, (req, res) => {
    res.json(db.prepare("SELECT id, date, notes, items, created_at FROM summaries WHERE user_id = ? AND org_id = ? AND kind = 'day' ORDER BY date DESC").all(req.session.userId, req.session.orgId)
      .map(({ notes, items, ...x }) => ({ ...x, headline: notes, items: JSON.parse(items) })));
  });

  // No team: owner/admin, whole org. With team: owner/admin any team, a lead only the teams they lead.
  r.get('/rollup', session, (req, res) => {
    const { orgId, userId, role } = req.session;
    const boss = role === 'owner' || role === 'admin';
    let only = null;
    if (req.query.team !== undefined) {
      const team = String(req.query.team);
      if (!db.prepare('SELECT 1 FROM org_projects WHERE id = ? AND org_id = ?').get(team, orgId)) throw notFound();
      if (!boss && !teamsFor(db, orgId, userId, role).some((t) => t.id === team)) throw new ForbiddenError();
      only = JSON.stringify(teamMemberUserIds(db, team));
    } else if (!boss) throw new ForbiddenError();
    res.json(db.prepare(`SELECT s.date, s.user_id, COALESCE(u.name, u.email) AS name, s.notes, s.items FROM summaries s JOIN users u ON u.id = s.user_id
      WHERE s.org_id = ? AND s.kind = 'day' AND (? IS NULL OR s.user_id IN (SELECT value FROM json_each(?))) ORDER BY s.date DESC, name`).all(orgId, only, only)
      .map(({ notes, items, ...x }) => ({ ...x, headline: notes, items: JSON.parse(items) })));
  });

  r.post('/org/import', deviceAuth(db), (req, res) => {
    const { userId, orgId } = req.device;
    const m = db.prepare('SELECT role FROM memberships WHERE user_id = ? AND org_id = ?').get(userId, orgId);
    if (!['owner', 'admin'].includes(m?.role)) throw new ForbiddenError();
    importOrg(db, orgId, req.body);
    res.json({ ok: true });
  });

  const orgAdmin = requireRole(db, 'owner', 'admin');
  const orgRow = (table, id, orgId) => {
    const row = db.prepare(`SELECT * FROM ${table} WHERE id = ? AND org_id = ?`).get(id, orgId);
    if (!row) throw notFound();
    return row;
  };

  r.get('/org', orgAdmin, (req, res) => res.json(orgView(db, req.session.orgId)));

  r.get('/teams', session, (req, res) => res.json(teamsFor(db, req.session.orgId, req.session.userId, req.session.role)));

  r.patch('/org/projects/:id', orgAdmin, (req, res) => {
    const p = orgRow('org_projects', req.params.id, req.session.orgId);
    const { name, archived } = req.body ?? {};
    if (name !== undefined && !(str(name) && name.trim().length <= 200)) throw bad('bad name');
    if (archived !== undefined && typeof archived !== 'boolean') throw bad('bad archived');
    db.prepare('UPDATE org_projects SET name = ?, name_by_hand = ?, archived = ? WHERE id = ?')
      .run(name === undefined ? p.name : name.trim(), name === undefined ? p.name_by_hand : 1, archived === undefined ? p.archived : +archived, p.id);
    res.json({ ok: true });
  });

  const memberPath = (req) => [orgRow('org_projects', req.params.id, req.session.orgId).id, orgRow('org_people', req.params.personId, req.session.orgId).id];
  r.put('/org/projects/:id/members/:personId', orgAdmin, (req, res) => {
    const role = req.body?.role;
    if (!['lead', 'member'].includes(role)) throw bad('bad role');
    db.prepare(`INSERT INTO project_members (project_id, person_id, role, role_by_hand, removed) VALUES (?,?,?,1,0)
      ON CONFLICT(project_id, person_id) DO UPDATE SET role = excluded.role, role_by_hand = 1, removed = 0`).run(...memberPath(req), role);
    res.json({ ok: true });
  });

  r.delete('/org/projects/:id/members/:personId', orgAdmin, (req, res) => {
    if (!db.prepare('UPDATE project_members SET removed = 1 WHERE project_id = ? AND person_id = ?').run(...memberPath(req)).changes) throw notFound();
    res.json({ ok: true });
  });

  r.patch('/org/people/:id', orgAdmin, (req, res) => {
    const p = orgRow('org_people', req.params.id, req.session.orgId);
    const u = req.body?.user_id;
    if (u !== null && !(str(u) && db.prepare('SELECT 1 FROM memberships WHERE user_id = ? AND org_id = ?').get(u, req.session.orgId))) throw bad('bad user_id');
    db.prepare('UPDATE org_people SET user_id = ?, linked_by_hand = 1 WHERE id = ?').run(u, p.id);
    res.json({ ok: true });
  });

  return r;
}

// Single place errors become HTTP: no stacks, no id-existence leaks.
export function errorHandler(err, req, res, next) {
  if (err instanceof ForbiddenError) return res.status(403).json({ error: 'forbidden' });
  if (err.message === 'item not found') return res.status(404).json({ error: 'not found' });
  if (err.status >= 400 && err.status < 500) return res.status(err.status).json({ error: err.message });
  console.error(err);
  res.status(500).json({ error: 'internal error' });
}
