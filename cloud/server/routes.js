import crypto from 'node:crypto';
import express from 'express';
import { readSession, issueSession, requireRole, verifyGoogle } from './auth.js';
import { redeemPairingCode, createPairingCode, deviceAuth } from './pairing.js';
import { mergeItems, adminView, redact, ownerEdit, release, ForbiddenError } from './summaries.js';

const uid = () => crypto.randomUUID();
const bad = (msg) => Object.assign(new Error(msg), { status: 400 });
const notFound = () => Object.assign(new Error('not found'), { status: 404 });
const str = (v) => typeof v === 'string' && v.trim() !== '';
const num = (v) => typeof v === 'number' && Number.isFinite(v) && v >= 0;

function validItem(i, partial = false) {
  if (!i || typeof i !== 'object') throw bad('bad item');
  if (!partial && !str(i.id)) throw bad('bad item id');
  if (i.what !== undefined || !partial) if (!str(i.what)) throw bad('bad what');
  if (i.minutes !== undefined || !partial) if (!num(i.minutes)) throw bad('bad minutes');
}

const KINDS = ['work', 'meeting', 'project'], VIS = ['admin', 'org'];
const parse = (row) => row && { ...row, items: JSON.parse(row.items) };

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
    req.session = s; next();
  };
  const membership = (userId) => db.prepare('SELECT org_id, role FROM memberships WHERE user_id = ?').get(userId);
  // Own row only; a missing row and someone else's row look identical (404).
  const ownRow = (req) => {
    const row = parse(db.prepare('SELECT * FROM summaries WHERE id = ? AND user_id = ? AND org_id = ?')
      .get(req.params.id, req.session.userId, req.session.orgId));
    if (!row) throw notFound();
    return row;
  };
  const save = (row) => db.prepare('UPDATE summaries SET items = ?, status = ? WHERE id = ?').run(JSON.stringify(row.items), row.status, row.id);

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

  r.post('/invites', requireRole('owner', 'admin'), (req, res) => {
    const role = req.body?.role ?? 'member';
    if (!['member', 'admin'].includes(role)) throw bad('bad role');
    if (role === 'admin' && req.session.role !== 'owner') throw new ForbiddenError('only owner invites admins');
    const token = crypto.randomBytes(24).toString('hex');
    db.prepare('INSERT INTO invites (id, org_id, token, role, created_at) VALUES (?,?,?,?,?)').run(uid(), req.session.orgId, token, role, Date.now());
    res.json({ token, role });
  });

  r.get('/members', requireRole('owner', 'admin'), (req, res) => {
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
    const { kind, date, items, notes = '' } = req.body ?? {};
    let { visibility } = req.body ?? {};
    if (!str(kind) || !str(date) || !Array.isArray(items)) throw bad('bad summary');
    items.forEach((i) => validItem(i));
    if (typeof notes !== 'string' || !KINDS.includes(kind)) throw bad('bad summary');
    if (visibility === undefined) visibility = kind === 'work' ? 'admin' : 'org'; // real client sends none
    if (!VIS.includes(visibility)) throw bad('bad summary');
    const clean = items.map(({ id, what, minutes }) => ({ id, what, minutes })); // server owns `removed`
    const { userId, orgId } = req.device; // never from the body
    db.transaction(() => {
      const ex = parse(db.prepare('SELECT * FROM summaries WHERE user_id=? AND org_id=? AND kind=? AND date=?').get(userId, orgId, kind, date));
      if (!ex) {
        db.prepare('INSERT INTO summaries VALUES (?,?,?,?,?,?,?,?,?,?)').run(uid(), userId, orgId, kind, date,
          JSON.stringify(mergeItems([], clean)), notes, visibility, 'pending', Date.now());
      } else if (ex.status === 'pending') { // released summaries are frozen: no re-push edits
        db.prepare('UPDATE summaries SET items=?, notes=?, visibility=? WHERE id=?').run(JSON.stringify(mergeItems(ex.items, clean)), notes, visibility, ex.id);
      }
    })();
    res.json({ ok: true });
  });

  r.get('/summaries/mine', session, (req, res) => {
    res.json(db.prepare('SELECT * FROM summaries WHERE user_id = ? AND org_id = ? ORDER BY date DESC').all(req.session.userId, req.session.orgId).map(parse));
  });

  r.post('/summaries/:id/redact', session, (req, res) => {
    if (!str(req.body?.itemId)) throw bad('itemId required');
    const row = ownRow(req);
    save(redact(row, req.body.itemId, req.session.role));
    res.json(row);
  });

  r.post('/summaries/:id/release', session, (req, res) => {
    const row = ownRow(req);
    save(release(row, req.session.role));
    res.json(row);
  });

  r.patch('/summaries/:id/items/:itemId', requireRole('owner'), (req, res) => {
    validItem(req.body, true);
    const { what, minutes } = req.body;
    const row = ownRow(req);
    save(ownerEdit(row, req.params.itemId, { what, minutes }, req.session.role));
    res.json(row);
  });

  r.get('/rollup', requireRole('owner', 'admin'), (req, res) => {
    const rows = db.prepare("SELECT * FROM summaries WHERE org_id = ? AND kind = 'work'").all(req.session.orgId);
    res.json(rows.map((x) => adminView(parse(x))).filter(Boolean).map((v) => ({
      date: v.date, user_id: v.user_id, items: v.items.map(({ id, what, minutes }) => ({ id, what, minutes })),
    })));
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
