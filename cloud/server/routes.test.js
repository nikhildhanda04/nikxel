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
  return { db, server, api, cookie, deviceFor, close: () => server.close() };
}
const A = (c, u = 'memA', r = 'member') => c.cookie(u, 'A', r);

test('orgs, invites, join, pairing', async () => {
  const c = await boot();
  c.db.prepare('INSERT INTO users VALUES (?,?,?,?,?)').run('newU', 'sub-n', 'n@x.com', 'n', 1);
  const none = { cookie: 'nikxel_session=' + signCookie({ userId: 'newU', orgId: null, role: null, exp: Date.now() + 1e6 }, S) };
  assert.equal((await c.api('POST', '/api/invites', { headers: A(c) , body: {} })).status, 403);
  const inv = await c.api('POST', '/api/invites', { headers: A(c, 'owA', 'owner'), body: { role: 'member' } });
  assert.equal(inv.status, 200); assert.equal(inv.json.role, 'member');
  assert.equal((await c.api('POST', '/api/invites', { headers: A(c, 'admA', 'admin'), body: { role: 'admin' } })).status, 200);
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
  assert.equal((await c.api('GET', '/api/auth/google/callback?code=abc')).status, 401); // no state
  assert.equal((await c.api('GET', '/api/auth/google/callback?code=abc&state=zz', { headers: { cookie: 'nikxel_oauth_state=other' } })).status, 401);
  const r = await c.api('GET', '/api/auth/google/callback?code=abc&state=good', { headers: { cookie: 'nikxel_oauth_state=good' } });
  assert.equal(r.status, 302); assert.equal(r.res.headers.get('location'), '/');
  assert.match(r.res.headers.get('set-cookie'), /nikxel_session=/);
  assert.equal(c.db.prepare('SELECT COUNT(*) n FROM users').get().n, 5); // upsert, no dup
  const g = await c.api('GET', '/api/auth/google');
  assert.match(g.res.headers.get('set-cookie'), /nikxel_oauth_state=/);
  assert.equal(g.status, 302); assert.match(g.res.headers.get('location'), /accounts\.google\.com.*client_id=cid.*scope=openid/);
  c.close();
});

test('google verify failure is 401', async () => {
  const c = await boot({ exchange: async () => ({ id_token: 't' }), verifier: async () => ({ sub: 'x', email_verified: false }) });
  const r = await c.api('GET', '/api/auth/google/callback?code=a&state=s', { headers: { cookie: 'nikxel_oauth_state=s' } });
  assert.equal(r.status, 401);
  c.close();
});

test('dev login is 404 unless DEV_LOGIN=1; /me returns session identity', async () => {
  const c = await boot();
  delete process.env.DEV_LOGIN;
  assert.equal((await c.api('POST', '/api/dev/login', { body: { userId: 'owA' } })).status, 404);
  process.env.DEV_LOGIN = '1';
  const ok = await c.api('POST', '/api/dev/login', { body: { userId: 'owA' } });
  delete process.env.DEV_LOGIN;
  assert.equal(ok.status, 200);
  const me = await c.api('GET', '/api/me', { headers: A(c, 'owA', 'owner') });
  assert.deepEqual(me.json, { userId: 'owA', orgId: 'A', role: 'owner', name: 'owA' });
  assert.equal((await c.api('GET', '/api/me')).status, 401);
  c.close();
});

test('admin can invite an admin; member cannot', async () => {
  const c = await boot();
  const r = await c.api('POST', '/api/invites', { headers: A(c, 'admA', 'admin'), body: { role: 'admin' } });
  assert.equal(r.status, 200); assert.equal(r.json.role, 'admin');
  assert.equal((await c.api('POST', '/api/invites', { headers: A(c), body: { role: 'admin' } })).status, 403);
  c.close();
});

test('role changes apply live, owner is fixed, orgs isolated', async () => {
  const c = await boot();
  const adm = A(c, 'admA', 'admin');
  assert.equal((await c.api('PATCH', '/api/members/memA', { headers: adm, body: { role: 'admin' } })).status, 200);
  assert.equal((await c.api('GET', '/api/rollup', { headers: A(c) })).status, 200); // old member cookie
  assert.equal((await c.api('PATCH', '/api/members/admA', { headers: A(c, 'owA', 'owner'), body: { role: 'member' } })).status, 200);
  assert.equal((await c.api('GET', '/api/rollup', { headers: adm })).status, 403); // old admin cookie
  assert.equal((await c.api('GET', '/api/me', { headers: adm })).json.role, 'member');
  assert.equal((await c.api('PATCH', '/api/members/owA', { headers: A(c, 'memA', 'admin'), body: { role: 'member' } })).status, 403);
  assert.equal((await c.api('PATCH', '/api/members/memA', { headers: c.cookie('owB', 'B', 'owner'), body: { role: 'admin' } })).status, 404);
  assert.equal((await c.api('PATCH', '/api/members/memA2', { headers: A(c, 'owA', 'owner'), body: { role: 'owner' } })).status, 400);
  c.close();
});

test('logout clears cookie', async () => {
  const c = await boot();
  const r = await c.api('POST', '/api/auth/logout');
  assert.equal(r.status, 200);
  assert.match(r.res.headers.get('set-cookie'), /nikxel_session=;/);
  c.close();
});

const I = (id, o = {}) => ({ id, section: 'Work', what: 'w' + id, type: 'coding', minutes: 30, details: [], project: '', ...o });
const push = (c, dev, items, o = {}) => c.api('POST', '/api/summaries', { headers: dev, body: { kind: 'day', date: '2026-11-20', headline: 'H', items, ...o } });

test('send replaces the day; rollup shows it with name', async () => {
  const c = await boot(); const dev = c.deviceFor('memA', 'A');
  assert.equal((await push(c, dev, [I('a'), I('b')])).status, 200);
  assert.equal((await push(c, dev, [I('a')], { headline: 'H2' })).status, 200);
  const mine = (await c.api('GET', '/api/summaries/mine', { headers: A(c) })).json;
  assert.equal(mine.length, 1); assert.deepEqual(mine[0].items, [I('a')]);
  const roll = (await c.api('GET', '/api/rollup', { headers: A(c, 'admA', 'admin') })).json;
  assert.equal(roll.length, 1); assert.equal(roll[0].name, 'memA'); assert.equal(roll[0].headline, 'H2');
  assert.equal((await c.api('GET', '/api/rollup', { headers: A(c) })).status, 403);
  await push(c, dev, [I('p', { project: 'Produce POS' })]);
  assert.equal((await c.api('GET', '/api/summaries/mine', { headers: A(c) })).json[0].items[0].project, 'Produce POS');
  assert.equal((await c.api('GET', '/api/rollup', { headers: A(c, 'admA', 'admin') })).json[0].items[0].project, 'Produce POS');
  assert.equal((await c.api('GET', '/api/rollup', { headers: c.cookie('owB', 'B', 'owner') })).json.length, 0);
  c.close();
});

test('push rejects non-day kind/bad body; body cannot redirect org/user; old routes gone', async () => {
  const c = await boot(); const dev = c.deviceFor('memA', 'A');
  assert.equal((await push(c, dev, [I('a')], { kind: 'work' })).status, 400);
  assert.equal((await push(c, dev, [I('a')], { date: 'nope' })).status, 400);
  assert.equal((await push(c, dev, [I('a')], { org_id: 'B', user_id: 'owB' })).status, 200);
  assert.deepEqual(c.db.prepare('SELECT org_id,user_id FROM summaries').get(), { org_id: 'A', user_id: 'memA' });
  assert.equal((await c.api('POST', '/api/summaries', { body: {} })).status, 401);
  assert.equal((await c.api('POST', '/api/summaries/x/release', { headers: A(c) })).status, 404);
  c.close();
});
