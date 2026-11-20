import test from 'node:test';
import assert from 'node:assert/strict';
import { openDb, bootstrap } from './db.js';
import { signCookie } from './auth.js';
import { createPairingCode, redeemPairingCode } from './pairing.js';
import { createApp } from './app.js';

process.env.SESSION_SECRET = 'test-secret-0123456789abcdef';
const S = process.env.SESSION_SECRET;

async function boot(opts = {}) {
  const db = openDb(':memory:'); bootstrap(db);
  const now = Date.now();
  const user = (id) => db.prepare('INSERT INTO users VALUES (?,?,?,?,?)').run(id, 'sub-' + id, id + '@x.com', id, now);
  const org = (id, owner) => db.prepare('INSERT INTO orgs VALUES (?,?,?,?)').run(id, id, owner, now);
  const mem = (u, o, r) => db.prepare('INSERT INTO memberships VALUES (?,?,?)').run(u, o, r);
  for (const u of ['owA', 'admA', 'memA', 'memA2', 'owB']) user(u);
  org('A', 'owA'); org('B', 'owB');
  mem('owA', 'A', 'owner'); mem('admA', 'A', 'admin'); mem('memA', 'A', 'member'); mem('memA2', 'A', 'member'); mem('owB', 'B', 'owner');
  const app = createApp(db, opts);
  const server = await new Promise((r) => { const s = app.listen(0, () => r(s)); });
  const base = `http://127.0.0.1:${server.address().port}`;
  const cookie = (userId, orgId, role) => ({ cookie: 'nikxel_session=' + signCookie({ userId, orgId, role, exp: Date.now() + 1e6 }, S) });
  const api = async (method, path, { headers = {}, body } = {}) => {
    const r = await fetch(base + path, { method, redirect: 'manual', headers: { 'content-type': 'application/json', ...headers }, body: body === undefined ? undefined : JSON.stringify(body) });
    let json = null; try { json = await r.json(); } catch {}
    return { status: r.status, json, res: r };
  };
  const deviceFor = (u, o) => ({ authorization: 'Bearer ' + redeemPairingCode(db, createPairingCode(db, u, o)).deviceToken });
  const seed = (id, userId, orgId, status, items, kind = 'work', date = '2026-11-20') =>
    db.prepare('INSERT INTO summaries VALUES (?,?,?,?,?,?,?,?,?,?)').run(id, userId, orgId, kind, date, JSON.stringify(items), '', 'private', status, now);
  const item = (id, minutes = 30, removed = false) => ({ id, what: 'w' + id, minutes, removed });
  return { db, server, api, cookie, deviceFor, seed, item, close: () => server.close() };
}
const A = (c, u = 'memA', r = 'member') => c.cookie(u, 'A', r);

test('member PATCH of item facts is rejected (403)', async () => {
  const c = await boot(); c.seed('s1', 'memA', 'A', 'pending', [c.item('i1')]);
  const r = await c.api('PATCH', '/api/summaries/s1/items/i1', { headers: A(c), body: { minutes: 999 } });
  assert.equal(r.status, 403);
  assert.equal(JSON.parse(c.db.prepare('SELECT items FROM summaries WHERE id=?').get('s1').items)[0].minutes, 30);
  c.close();
});

test('owner PATCH edits facts while pending; validates body; owns row', async () => {
  const c = await boot(); c.seed('s1', 'owA', 'A', 'pending', [c.item('i1')]); c.seed('s2', 'memA', 'A', 'pending', [c.item('i1')]);
  const h = A(c, 'owA', 'owner');
  assert.equal((await c.api('PATCH', '/api/summaries/s1/items/i1', { headers: h, body: { minutes: -1 } })).status, 400);
  assert.equal((await c.api('PATCH', '/api/summaries/s1/items/i1', { headers: h, body: { what: '' } })).status, 400);
  assert.equal((await c.api('PATCH', '/api/summaries/s1/items/nope', { headers: h, body: { minutes: 5 } })).status, 404);
  assert.equal((await c.api('PATCH', '/api/summaries/s2/items/i1', { headers: h, body: { minutes: 5 } })).status, 404); // not own row
  const r = await c.api('PATCH', '/api/summaries/s1/items/i1', { headers: h, body: { minutes: 45 } });
  assert.equal(r.status, 200);
  assert.equal(JSON.parse(c.db.prepare('SELECT items FROM summaries WHERE id=?').get('s1').items)[0].minutes, 45);
  c.close();
});

test('admin rollup excludes pending and other orgs', async () => {
  const c = await boot();
  c.seed('a1', 'memA', 'A', 'released', [c.item('i1'), c.item('i2', 10, true)]);
  c.seed('a2', 'memA2', 'A', 'pending', [c.item('i1')]);
  c.seed('b1', 'owB', 'B', 'released', [c.item('i1')]);
  const r = await c.api('GET', '/api/rollup', { headers: A(c, 'admA', 'admin') });
  assert.equal(r.status, 200);
  assert.deepEqual(r.json.map((s) => s.id), ['a1']);
  assert.deepEqual(r.json[0].items.map((i) => i.id), ['i1']);
  assert.equal((await c.api('GET', '/api/rollup', { headers: A(c) })).status, 403);
  assert.equal((await c.api('GET', '/api/rollup')).status, 401);
  const m = await c.api('GET', '/api/members', { headers: A(c, 'admA', 'admin') });
  assert.deepEqual(m.json.map((x) => x.user_id).sort(), ['admA', 'memA', 'memA2', 'owA']);
  c.close();
});

test('push merges and preserves redactions', async () => {
  const c = await boot(); const dev = c.deviceFor('memA', 'A');
  const push = (items, extra = {}) => c.api('POST', '/api/summaries', { headers: dev, body: { kind: 'work', date: '2026-11-20', items, notes: '', visibility: 'private', ...extra } });
  assert.equal((await push([{ id: 'i1', what: 'a', minutes: 10 }, { id: 'i2', what: 'b', minutes: 5 }])).status, 200);
  assert.equal((await c.api('POST', '/api/summaries', { headers: dev, body: { kind: 'work', date: 'd', items: [{ id: 'x', what: 'a', minutes: 'ten' }] } })).status, 400);
  const mine = (await c.api('GET', '/api/summaries/mine', { headers: A(c) })).json;
  assert.equal(mine.length, 1); assert.equal(mine[0].status, 'pending');
  assert.equal((await c.api('POST', `/api/summaries/${mine[0].id}/redact`, { headers: A(c), body: { itemId: 'i1' } })).status, 200);
  assert.equal((await c.api('POST', `/api/summaries/${mine[0].id}/redact`, { headers: A(c), body: { itemId: 'zz' } })).status, 404);
  await push([{ id: 'i1', what: 'a2', minutes: 11 }, { id: 'i3', what: 'c', minutes: 1 }]);
  const after = (await c.api('GET', '/api/summaries/mine', { headers: A(c) })).json;
  assert.equal(after.length, 1);
  const by = Object.fromEntries(after[0].items.map((i) => [i.id, i]));
  assert.equal(by.i1.removed, true); assert.equal(by.i1.minutes, 11); assert.equal(by.i3.removed, false);
  // body can't redirect org/user
  await c.api('POST', '/api/summaries', { headers: dev, body: { kind: 'work', date: '2026-11-21', items: [], org_id: 'B', user_id: 'owB' } });
  assert.equal(c.db.prepare("SELECT org_id,user_id FROM summaries WHERE date='2026-11-21'").get().org_id, 'A');
  assert.equal((await c.api('POST', '/api/summaries', { body: {} })).status, 401);
  c.close();
});

test('release makes a summary appear in the rollup; only owner of row may', async () => {
  const c = await boot(); c.seed('s1', 'memA', 'A', 'pending', [c.item('i1')]);
  const admin = A(c, 'admA', 'admin');
  assert.equal((await c.api('GET', '/api/rollup', { headers: admin })).json.length, 0);
  assert.equal((await c.api('POST', '/api/summaries/s1/release', { headers: A(c, 'memA2') })).status, 404);
  assert.equal((await c.api('POST', '/api/summaries/s1/release', { headers: A(c, 'admA', 'admin') })).status, 404);
  assert.equal((await c.api('POST', '/api/summaries/s1/release', { headers: A(c) })).status, 200);
  assert.deepEqual((await c.api('GET', '/api/rollup', { headers: admin })).json.map((s) => s.id), ['s1']);
  assert.equal((await c.api('POST', '/api/summaries/s1/redact', { headers: A(c), body: { itemId: 'i1' } })).status, 403);
  c.close();
});

test('orgs, invites, join, pairing', async () => {
  const c = await boot();
  c.db.prepare('INSERT INTO users VALUES (?,?,?,?,?)').run('newU', 'sub-n', 'n@x.com', 'n', 1);
  const none = { cookie: 'nikxel_session=' + signCookie({ userId: 'newU', orgId: null, role: null, exp: Date.now() + 1e6 }, S) };
  assert.equal((await c.api('POST', '/api/invites', { headers: A(c) , body: {} })).status, 403);
  const inv = await c.api('POST', '/api/invites', { headers: A(c, 'owA', 'owner'), body: { role: 'member' } });
  assert.equal(inv.status, 200); assert.equal(inv.json.role, 'member');
  assert.equal((await c.api('POST', '/api/invites', { headers: A(c, 'admA', 'admin'), body: { role: 'admin' } })).status, 403);
  const j = await c.api('POST', '/api/orgs/join', { headers: none, body: { token: inv.json.token } });
  assert.equal(j.status, 200);
  assert.equal(c.db.prepare("SELECT role FROM memberships WHERE user_id='newU'").get().role, 'member');
  assert.equal((await c.api('POST', '/api/orgs/join', { headers: A(c, 'owB', 'owner'), body: { token: inv.json.token } })).status, 409);
  const o = await c.api('POST', '/api/orgs', { headers: none, body: { name: 'X' } });
  assert.equal(o.status, 409); // already member now via join
  c.db.prepare('INSERT INTO users VALUES (?,?,?,?,?)').run('u3', 'sub-3', 'u3@x.com', 'u3', 1);
  const none3 = { cookie: 'nikxel_session=' + signCookie({ userId: 'u3', orgId: null, role: null, exp: Date.now() + 1e6 }, S) };
  assert.equal((await c.api('POST', '/api/orgs', { headers: none3, body: { name: 'Three' } })).status, 200);
  assert.equal(c.db.prepare("SELECT role FROM memberships WHERE user_id='u3'").get().role, 'owner');
  const code = (await c.api('GET', '/api/pairing-code', { headers: A(c) })).json.code;
  const p = await c.api('POST', '/api/pair', { body: { code } });
  assert.equal(p.status, 200); assert.match(p.json.deviceToken, /^[0-9a-f]{64}$/);
  assert.equal((await c.api('POST', '/api/pair', { body: { code } })).status, 400);
  c.close();
});

test('pair is rate limited per IP', async () => {
  const c = await boot(); let last;
  for (let i = 0; i < 12; i++) last = await c.api('POST', '/api/pair', { body: { code: '000000' } });
  assert.equal(last.status, 429);
  c.close();
});

test('google callback upserts by sub and issues session', async () => {
  process.env.GOOGLE_CLIENT_ID = 'cid'; process.env.GOOGLE_CLIENT_SECRET = 'sec'; process.env.GOOGLE_REDIRECT_URI = 'http://h/cb';
  const c = await boot({
    exchange: async () => ({ id_token: 't' }),
    verifier: async () => ({ sub: 'sub-memA', email: 'changed@x.com', name: 'M', email_verified: true }),
  });
  const r = await c.api('GET', '/api/auth/google/callback?code=abc');
  assert.equal(r.status, 302); assert.equal(r.res.headers.get('location'), '/');
  assert.match(r.res.headers.get('set-cookie'), /nikxel_session=/);
  assert.equal(c.db.prepare('SELECT COUNT(*) n FROM users').get().n, 5); // upsert, no dup
  const g = await c.api('GET', '/api/auth/google');
  assert.equal(g.status, 302); assert.match(g.res.headers.get('location'), /accounts\.google\.com.*client_id=cid.*scope=openid/);
  c.close();
});
