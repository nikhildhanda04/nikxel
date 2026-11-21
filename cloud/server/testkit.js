import { openDb, bootstrap } from './db.js';
import { signCookie } from './auth.js';
import { createPairingCode, redeemPairingCode } from './pairing.js';
import { createApp } from './app.js';

process.env.SESSION_SECRET = 'test-secret-0123456789abcdef';
export const S = process.env.SESSION_SECRET;

export async function boot(opts = {}) {
  const db = openDb(':memory:'); bootstrap(db);
  const now = Date.now();
  const user = (id) => db.prepare('INSERT INTO users VALUES (?,?,?,?,?)').run(id, 'sub-' + id, id + '@x.com', id, now);
  const org = (id, owner) => db.prepare('INSERT INTO orgs VALUES (?,?,?,?)').run(id, id, owner, now);
  const mem = (u, o, r) => db.prepare('INSERT INTO memberships VALUES (?,?,?)').run(u, o, r);
  for (const u of ['owA', 'cofA', 'admA', 'memA', 'memA2', 'owB']) user(u);
  org('A', 'owA'); org('B', 'owB');
  mem('owA', 'A', 'owner'); mem('cofA', 'A', 'cofounder'); mem('admA', 'A', 'admin'); mem('memA', 'A', 'member'); mem('memA2', 'A', 'member'); mem('owB', 'B', 'owner');
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
