import test from 'node:test';
import assert from 'node:assert/strict';
import { signCookie } from './auth.js';
import { createPairingCode, redeemPairingCode } from './pairing.js';
import { boot, S } from './testkit.js';

const A = (c, u = 'memA', r = 'member') => c.cookie(u, 'A', r);

test('orgs, invites, join, pairing', async () => {
  const c = await boot();
  c.db.prepare('INSERT INTO users VALUES (?,?,?,?,?)').run('newU', 'sub-n', 'n@x.com', 'n', 1);
  const none = { cookie: 'nikxel_session=' + signCookie({ userId: 'newU', orgId: null, role: null, exp: Date.now() + 1e6 }, S) };
  assert.equal((await c.api('POST', '/api/invites', { headers: A(c) , body: {} })).status, 200);
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
  assert.equal(c.db.prepare('SELECT COUNT(*) n FROM users').get().n, 6); // upsert, no dup
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

test('invite role rules', async () => {
  const c = await boot();
  const inv = (u, r, role) => c.api('POST', '/api/invites', { headers: A(c, u, r), body: { role } }).then((x) => x.status);
  assert.equal(await inv('memA', 'member', 'member'), 200);
  assert.equal(await inv('memA', 'member', 'admin'), 403);
  assert.equal(await inv('admA', 'admin', 'admin'), 200);
  assert.equal(await inv('admA', 'admin', 'cofounder'), 403);
  assert.equal(await inv('cofA', 'cofounder', 'cofounder'), 403);
  assert.equal(await inv('owA', 'owner', 'cofounder'), 200);
  assert.equal(await inv('owA', 'owner', 'owner'), 400);
  c.close();
});

test('role changes apply live, owner is fixed, orgs isolated', async () => {
  const c = await boot();
  const adm = A(c, 'admA', 'admin');
  assert.equal((await c.api('PATCH', '/api/members/memA', { headers: adm, body: { role: 'admin' } })).status, 200);
  assert.equal((await c.api('GET', '/api/summaries/user/owA', { headers: A(c) })).status, 200); // old member cookie
  assert.equal((await c.api('PATCH', '/api/members/admA', { headers: A(c, 'owA', 'owner'), body: { role: 'member' } })).status, 200);
  assert.equal((await c.api('GET', '/api/summaries/user/owA', { headers: adm })).status, 403); // old admin cookie
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

test('send replaces the day; staff read it per user', async () => {
  const c = await boot(); const dev = c.deviceFor('memA', 'A');
  assert.equal((await push(c, dev, [I('a'), I('b')])).status, 200);
  assert.equal((await push(c, dev, [I('a')], { headline: 'H2' })).status, 200);
  const mine = (await c.api('GET', '/api/summaries/mine', { headers: A(c) })).json;
  assert.equal(mine.length, 1); assert.deepEqual(mine[0].items, [I('a')]);
  const ru = (u, r, id = 'memA') => c.api('GET', '/api/summaries/user/' + id, { headers: A(c, u, r) });
  const seen = (await ru('admA', 'admin')).json;
  assert.equal(seen.length, 1); assert.equal(seen[0].headline, 'H2');
  assert.equal((await ru('memA2', 'member')).status, 403);
  await push(c, dev, [I('p', { project: 'Produce POS' })]);
  assert.equal((await c.api('GET', '/api/summaries/mine', { headers: A(c) })).json[0].items[0].project, 'Produce POS');
  assert.equal((await ru('admA', 'admin')).json[0].items[0].project, 'Produce POS');
  assert.equal((await c.api('GET', '/api/summaries/user/memA', { headers: c.cookie('owB', 'B', 'owner') })).status, 404);
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

test('members list, role changes, removal', async () => {
  const c = await boot();
  const as = (u, r) => A(c, u, r);
  const patch = (u, r, id, role) => c.api('PATCH', '/api/members/' + id, { headers: as(u, r), body: { role } }).then((x) => x.status);
  const del = (u, r, id) => c.api('DELETE', '/api/members/' + id, { headers: as(u, r) }).then((x) => x.status);
  const list = await c.api('GET', '/api/members', { headers: A(c) });
  assert.equal(list.status, 200); assert.equal(list.json.length, 5);
  assert.deepEqual(Object.keys(list.json[0]).sort(), ['email', 'name', 'role', 'user_id']);
  assert.equal(await patch('admA', 'admin', 'memA', 'admin'), 200);
  assert.equal(await patch('admA', 'admin', 'memA', 'cofounder'), 403);
  assert.equal(await patch('owA', 'owner', 'memA', 'cofounder'), 200);
  assert.equal(await patch('admA', 'admin', 'memA', 'member'), 403); // revoking cofounder is owner-only
  assert.equal(await patch('cofA', 'cofounder', 'owA', 'member'), 403);
  assert.equal(await patch('memA2', 'member', 'memA2', 'admin'), 403);
  c.db.prepare("INSERT INTO projects VALUES ('pA','A','PA','','owA',1,0), ('pB','B','PB','','owB',1,0)").run();
  c.db.prepare("INSERT INTO project_users VALUES ('pA','memA2',1), ('pB','memA2',1)").run();
  const dev = c.deviceFor('memA2', 'A');
  const code = createPairingCode(c.db, 'memA2', 'A');
  assert.equal((await push(c, dev, [I('a')])).status, 200);
  assert.equal(await del('admA', 'admin', 'memA2'), 200);
  assert.equal((await push(c, dev, [I('a')])).status, 401);
  assert.equal(c.db.prepare("SELECT COUNT(*) n FROM summaries WHERE user_id='memA2'").get().n, 1);
  assert.equal(c.db.prepare("SELECT COUNT(*) n FROM memberships WHERE user_id='memA2'").get().n, 0);
  assert.equal(c.db.prepare("SELECT project_id FROM project_users WHERE user_id='memA2'").all().map((r) => r.project_id).join(), 'pB');
  assert.equal(redeemPairingCode(c.db, code), null); // unredeemed code died with the membership
  assert.equal(await del('cofA', 'cofounder', 'owA'), 403);
  assert.equal(await del('admA', 'admin', 'cofA'), 403);
  assert.equal(await del('owA', 'owner', 'cofA'), 200);
  assert.equal((await c.api('DELETE', '/api/members/memA', { headers: c.cookie('owB', 'B', 'owner') })).status, 404);
  c.close();
});

test('rollup, org and teams are gone', async () => {
  const c = await boot();
  for (const p of ['rollup', 'org', 'teams']) assert.equal((await c.api('GET', '/api/' + p, { headers: A(c, 'owA', 'owner') })).status, 404);
  c.close();
});

test('device token without a live membership is 401', async () => {
  const c = await boot(); const dev = c.deviceFor('memA2', 'A');
  assert.equal((await push(c, dev, [I('a')])).status, 200);
  c.db.prepare("DELETE FROM memberships WHERE user_id='memA2'").run();
  assert.equal((await push(c, dev, [I('a')])).status, 401);
  c.close();
});
