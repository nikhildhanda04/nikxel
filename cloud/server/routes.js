import crypto from 'node:crypto';
import express from 'express';
import { readSession, issueSession, liveSession, requireRole, verifyGoogle, STAFF } from './auth.js';
import { redeemPairingCode, createPairingCode, deviceAuth } from './pairing.js';
import { projectRouter } from './projects.js';
import { cleanDay, ForbiddenError } from './summaries.js';

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

  const ROLES = ['cofounder', 'admin', 'member'];
  const anyMember = requireRole(db, 'owner', ...ROLES);
  const staff = requireRole(db, ...STAFF);
  r.post('/invites', anyMember, (req, res) => {
    const role = req.body?.role ?? 'member';
    if (!ROLES.includes(role)) throw bad('bad role');
    const me = req.session.role;
    if (role === 'cofounder' ? me !== 'owner' : role === 'admin' && !STAFF.includes(me)) throw new ForbiddenError();
    const token = crypto.randomBytes(24).toString('hex');
    db.prepare('INSERT INTO invites (id, org_id, token, role, created_at) VALUES (?,?,?,?,?)').run(uid(), req.session.orgId, token, role, Date.now());
    res.json({ token, role });
  });

  const target = (req) => {
    const t = db.prepare('SELECT role FROM memberships WHERE user_id = ? AND org_id = ?').get(req.params.userId, req.session.orgId);
    if (!t) throw notFound();
    if (t.role === 'owner') throw new ForbiddenError('owner role is fixed');
    return t;
  };

  r.patch('/members/:userId', staff, (req, res) => {
    const role = req.body?.role;
    if (!ROLES.includes(role)) throw bad('bad role');
    const t = target(req);
    if ((role === 'cofounder' || t.role === 'cofounder') && req.session.role !== 'owner') throw new ForbiddenError();
    db.prepare('UPDATE memberships SET role = ? WHERE user_id = ? AND org_id = ?').run(role, req.params.userId, req.session.orgId);
    res.json({ user_id: req.params.userId, role });
  });

  r.delete('/members/:userId', staff, (req, res) => {
    const t = target(req), { orgId } = req.session;
    if (t.role === 'cofounder' && req.session.role !== 'owner') throw new ForbiddenError();
    db.transaction(() => {
      db.prepare('DELETE FROM memberships WHERE user_id = ? AND org_id = ?').run(req.params.userId, orgId);
      db.prepare('DELETE FROM device_tokens WHERE user_id = ? AND org_id = ?').run(req.params.userId, orgId);
      db.prepare('DELETE FROM pairing_codes WHERE user_id = ? AND org_id = ?').run(req.params.userId, orgId);
      db.prepare('DELETE FROM project_users WHERE user_id = ? AND project_id IN (SELECT id FROM projects WHERE org_id = ?)').run(req.params.userId, orgId);
    })();
    res.json({ ok: true });
  });

  r.post('/auth/logout', (req, res) => {
    res.clearCookie('nikxel_session', { httpOnly: true, sameSite: 'lax', secure: true, path: '/' });
    res.json({ ok: true });
  });

  r.get('/members', anyMember, (req, res) => {
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
    const find = db.prepare('SELECT p.id FROM projects p JOIN project_users pu ON pu.project_id = p.id WHERE pu.user_id = ? AND p.org_id = ? AND p.archived = 0 AND lower(p.name) = lower(?)');
    for (const i of items) if (i.project) i.project_id = find.get(userId, orgId, i.project)?.id ?? null;
    db.prepare(`INSERT INTO summaries VALUES (?,?,?,'day',?,?,?,'admin','sent',?)
      ON CONFLICT(user_id, org_id, kind, date) DO UPDATE SET items = excluded.items, notes = excluded.notes, created_at = excluded.created_at`)
      .run(uid(), userId, orgId, date, JSON.stringify(items), headline, Date.now());
    res.json({ ok: true });
  });

  const days = (userId, orgId) => db.prepare("SELECT id, date, notes, items, created_at FROM summaries WHERE user_id = ? AND org_id = ? AND kind = 'day' ORDER BY date DESC").all(userId, orgId)
    .map(({ notes, items, ...x }) => ({ ...x, headline: notes, items: JSON.parse(items) }));
  r.get('/summaries/mine', session, (req, res) => res.json(days(req.session.userId, req.session.orgId)));
  r.get('/summaries/user/:userId', staff, (req, res) => {
    if (!db.prepare('SELECT 1 FROM memberships WHERE user_id = ? AND org_id = ?').get(req.params.userId, req.session.orgId)) throw notFound();
    res.json(days(req.params.userId, req.session.orgId));
  });

  r.use(projectRouter(db, anyMember));

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
