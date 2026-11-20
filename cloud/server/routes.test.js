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

const orgBody = () => ({
  people: [['owA', 1], ['admA', 2], ['memA', 3], ['memA2', 4], ['memA3', 5]].map(([u, e]) => ({ erp_id: e, name: u, email: u.toUpperCase() + '@X.com', title: '', manager_erp_id: null, note: '' })),
  projects: [
    { erp_id: 10, name: 'P', description: '', active: true, members: [{ erp_id: 3, lead: true }, { erp_id: 4, lead: false }] },
    { erp_id: 11, name: 'Q', description: '', active: true, members: [{ erp_id: 5, lead: true }, { erp_id: 2, lead: false }] },
  ],
});
async function bootOrg() {
  const c = await boot();
  c.db.prepare('INSERT INTO users VALUES (?,?,?,?,?)').run('memA3', 'sub-memA3', 'memA3@x.com', 'memA3', 1);
  c.db.prepare('INSERT INTO memberships VALUES (?,?,?)').run('memA3', 'A', 'member');
  assert.equal((await c.api('POST', '/api/org/import', { headers: c.deviceFor('admA', 'A'), body: orgBody() })).status, 200);
  const pid = (n) => c.db.prepare('SELECT id FROM org_projects WHERE name = ?').get(n).id;
  const per = (e) => c.db.prepare('SELECT id FROM org_people WHERE erp_id = ?').get(e).id;
  return { ...c, pid, per };
}

test('org import and management are owner/admin only', async () => {
  const c = await bootOrg();
  assert.equal((await c.api('POST', '/api/org/import', { headers: c.deviceFor('memA', 'A'), body: orgBody() })).status, 403);
  assert.equal((await c.api('POST', '/api/org/import', { body: orgBody() })).status, 401);
  assert.equal((await c.api('POST', '/api/org/import', { headers: c.deviceFor('owA', 'A'), body: { people: 1 } })).status, 400);
  assert.equal((await c.api('GET', '/api/org', { headers: A(c) })).status, 403);
  const big = { people: Array.from({ length: 2000 }, (_, i) => ({ erp_id: 1000 + i, name: 'Person ' + i, email: `p${i}@example.com`, title: 'Senior Software Engineer', manager_erp_id: 1, note: 'n'.repeat(100) })), projects: [] };
  assert.equal((await c.api('POST', '/api/org/import', { headers: c.deviceFor('owA', 'A'), body: big })).status, 200);
  c.db.prepare('DELETE FROM org_people WHERE erp_id >= 1000').run();
  const v = (await c.api('GET', '/api/org', { headers: A(c, 'owA', 'owner') })).json;
  assert.equal(v.people.length, 5); assert.equal(v.people[0].joined, true);
  assert.equal((await c.api('GET', '/api/org', { headers: c.cookie('owB', 'B', 'owner') })).json.people.length, 0);
  const own = A(c, 'owA', 'owner'), P = c.pid('P');
  assert.equal((await c.api('PATCH', `/api/org/projects/${P}`, { headers: A(c), body: { name: 'X' } })).status, 403);
  assert.equal((await c.api('PATCH', `/api/org/projects/${P}`, { headers: c.cookie('owB', 'B', 'owner'), body: { name: 'X' } })).status, 404);
  assert.equal((await c.api('PATCH', `/api/org/projects/${P}`, { headers: own, body: { name: '' } })).status, 400);
  assert.equal((await c.api('PATCH', `/api/org/projects/${P}`, { headers: own, body: { name: 'P2', archived: true } })).status, 200);
  assert.deepEqual(c.db.prepare('SELECT name, name_by_hand, archived FROM org_projects WHERE id = ?').get(P), { name: 'P2', name_by_hand: 1, archived: 1 });
  const m = `/api/org/projects/${P}/members/${c.per(4)}`;
  assert.equal((await c.api('PUT', m, { headers: own, body: { role: 'boss' } })).status, 400);
  assert.equal((await c.api('DELETE', m, { headers: own })).status, 200);
  assert.equal(c.db.prepare('SELECT removed FROM project_members WHERE person_id = ?').get(c.per(4)).removed, 1);
  assert.equal((await c.api('PUT', m, { headers: own, body: { role: 'lead' } })).status, 200);
  assert.deepEqual(c.db.prepare('SELECT role, role_by_hand, removed FROM project_members WHERE person_id = ?').get(c.per(4)), { role: 'lead', role_by_hand: 1, removed: 0 });
  assert.equal((await c.api('PUT', `/api/org/projects/${P}/members/nope`, { headers: own, body: { role: 'lead' } })).status, 404);
  const pp = `/api/org/people/${c.per(5)}`;
  assert.equal((await c.api('PATCH', pp, { headers: own, body: { user_id: 'owB' } })).status, 400); // not in org
  assert.equal((await c.api('PATCH', pp, { headers: own, body: { user_id: null } })).status, 200);
  assert.deepEqual(c.db.prepare('SELECT user_id, linked_by_hand FROM org_people WHERE id = ?').get(c.per(5)), { user_id: null, linked_by_hand: 1 });
  assert.equal((await c.api('PATCH', pp, { headers: own, body: { user_id: 'memA3' } })).status, 200);
  c.close();
});

test('teams: owner all, lead own, member none', async () => {
  const c = await bootOrg();
  const names = async (h) => (await c.api('GET', '/api/teams', { headers: h })).json.map((t) => t.name);
  assert.deepEqual(await names(A(c, 'owA', 'owner')), ['P', 'Q']);
  assert.deepEqual(await names(A(c, 'memA')), ['P']);
  assert.deepEqual(await names(A(c, 'memA2')), []);
  assert.equal((await c.api('GET', '/api/teams')).status, 401);
  c.close();
});

test('rollup by team: lead sees only their team, others 403/404', async () => {
  const c = await bootOrg();
  for (const u of ['memA', 'memA2', 'memA3', 'admA']) await push(c, c.deviceFor(u, 'A'), [I('a')]);
  const P = c.pid('P'), Q = c.pid('Q');
  const r = await c.api('GET', `/api/rollup?team=${P}`, { headers: A(c, 'memA') });
  assert.equal(r.status, 200); assert.deepEqual(r.json.map((d) => d.user_id).sort(), ['memA', 'memA2']);
  assert.equal((await c.api('GET', `/api/rollup?team=${P}`, { headers: A(c, 'memA3') })).status, 403); // lead of Q
  assert.equal((await c.api('GET', `/api/rollup?team=${P}`, { headers: A(c, 'memA2') })).status, 403);
  assert.equal((await c.api('GET', '/api/rollup', { headers: A(c, 'memA') })).status, 403);
  assert.deepEqual((await c.api('GET', `/api/rollup?team=${Q}`, { headers: A(c, 'owA', 'owner') })).json.map((d) => d.user_id).sort(), ['admA', 'memA3']);
  assert.equal((await c.api('GET', `/api/rollup?team=${P}`, { headers: c.cookie('owB', 'B', 'owner') })).status, 404);
  assert.equal((await c.api('GET', '/api/rollup?team=nope', { headers: A(c, 'owA', 'owner') })).status, 404);
  assert.equal((await c.api('GET', '/api/rollup', { headers: A(c, 'owA', 'owner') })).json.length, 4);
  c.db.prepare("UPDATE project_members SET removed = 1 WHERE person_id = (SELECT id FROM org_people WHERE erp_id = 3)").run();
  assert.equal((await c.api('GET', `/api/rollup?team=${P}`, { headers: A(c, 'memA') })).status, 403); // removed lead
  c.close();
});

test('a lead who joins after the import is linked by email on join and on login; hand links win', async () => {
  process.env.GOOGLE_CLIENT_ID = 'cid'; process.env.GOOGLE_CLIENT_SECRET = 'sec'; process.env.GOOGLE_REDIRECT_URI = 'http://h/cb';
  const c = await boot({ exchange: async () => ({ id_token: 't' }), verifier: async () => ({ sub: 'sub-login', email: 'Login@X.com', name: 'L', email_verified: true }) });
  const body = orgBody(); body.people.push({ erp_id: 6, name: 'late', email: 'late@x.com' }, { erp_id: 7, name: 'login', email: 'login@x.com' }, { erp_id: 8, name: 'hand', email: 'hand@x.com' });
  body.projects[0].members.push({ erp_id: 6, lead: true }, { erp_id: 7, lead: true });
  body.projects[1].members.push({ erp_id: 8, lead: true });
  await c.api('POST', '/api/org/import', { headers: c.deviceFor('owA', 'A'), body });
  const hand = c.db.prepare('SELECT id FROM org_people WHERE erp_id = 8').get().id;
  assert.equal((await c.api('PATCH', `/api/org/people/${hand}`, { headers: A(c, 'owA', 'owner'), body: { user_id: null } })).status, 200);
  // join via invite
  c.db.prepare('INSERT INTO users VALUES (?,?,?,?,?)').run('late', 'sub-late', 'LATE@x.com', 'late', 1);
  c.db.prepare('INSERT INTO users VALUES (?,?,?,?,?)').run('hand', 'sub-hand', 'hand@x.com', 'hand', 1);
  for (const u of ['late', 'hand']) {
    const tok = (await c.api('POST', '/api/invites', { headers: A(c, 'owA', 'owner'), body: {} })).json.token;
    assert.equal((await c.api('POST', '/api/orgs/join', { headers: c.cookie(u, null, null), body: { token: tok } })).status, 200);
  }
  assert.deepEqual((await c.api('GET', '/api/teams', { headers: A(c, 'late') })).json.map((t) => t.name), ['P']);
  assert.deepEqual((await c.api('GET', '/api/teams', { headers: A(c, 'hand') })).json, []); // hand unlink wins
  // already a member, not yet linked (e.g. joined before the import): linked on login
  c.db.prepare('INSERT INTO users VALUES (?,?,?,?,?)').run('login', 'sub-login', 'login@x.com', 'login', 1);
  c.db.prepare("INSERT INTO memberships VALUES ('login','A','member')").run();
  c.db.prepare("UPDATE org_people SET user_id = NULL WHERE erp_id = 7").run();
  assert.equal((await c.api('GET', '/api/auth/google/callback?code=a&state=s', { headers: { cookie: 'nikxel_oauth_state=s' } })).status, 302);
  assert.equal(c.db.prepare('SELECT user_id FROM org_people WHERE erp_id = 7').get().user_id, 'login');
  c.close();
});

test('lead paths need a live membership; cross-org member/person ids are 404', async () => {
  const c = await bootOrg();
  c.db.prepare("DELETE FROM memberships WHERE user_id = 'memA'").run(); // org_people link still there
  assert.equal((await c.api('GET', `/api/rollup?team=${c.pid('P')}`, { headers: A(c, 'memA') })).status, 403);
  assert.equal((await c.api('GET', '/api/teams', { headers: A(c, 'memA') })).status, 403);
  const ownB = c.cookie('owB', 'B', 'owner');
  assert.equal((await c.api('DELETE', `/api/org/projects/${c.pid('P')}/members/${c.per(4)}`, { headers: ownB })).status, 404);
  assert.equal((await c.api('PATCH', `/api/org/people/${c.per(5)}`, { headers: ownB, body: { user_id: null } })).status, 404);
  c.close();
});
