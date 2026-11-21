import test from 'node:test';
import assert from 'node:assert/strict';
import { openDb, bootstrap } from './db.js';
import { createPairingCode, redeemPairingCode, deviceAuth } from './pairing.js';

const fakeRes = () => ({
  statusCode: 200, body: undefined,
  status(c) { this.statusCode = c; return this; },
  json(b) { this.body = b; return this; },
});
const mk = () => { const db = openDb(':memory:'); bootstrap(db); return db; };

test('pair → redeem issues a token; code is single-use', () => {
  const db = mk();
  const code = createPairingCode(db, 'u1', 'o1');
  assert.match(code, /^\d{6}$/);
  const first = redeemPairingCode(db, code);
  assert.ok(first.deviceToken && first.userId === 'u1' && first.orgId === 'o1');
  assert.equal(redeemPairingCode(db, code), null);
});
test('expired code cannot be redeemed (boundary inclusive)', () => {
  const db = mk();
  const t0 = 1_000_000;
  const code = createPairingCode(db, 'u1', 'o1', () => t0);
  assert.equal(redeemPairingCode(db, code, () => t0 + 10 * 60 * 1000), null);
  assert.equal(redeemPairingCode(db, code, () => t0 + 11 * 60 * 1000), null);
});
test('only the hash of the token is stored', () => {
  const db = mk();
  db.prepare("INSERT INTO memberships VALUES ('u1','o1','member')").run();
  const { deviceToken } = redeemPairingCode(db, createPairingCode(db, 'u1', 'o1'));
  const rows = db.prepare('SELECT * FROM device_tokens').all();
  assert.equal(rows.length, 1);
  assert.notEqual(rows[0].token_hash, deviceToken);
  assert.equal(rows[0].org_id, 'o1');
});
test('deviceAuth resolves a valid bearer, rejects unknown/missing', () => {
  const db = mk();
  const { deviceToken } = redeemPairingCode(db, createPairingCode(db, 'u1', 'o1'));
  const mw = deviceAuth(db);
  const okReq = { headers: { authorization: `Bearer ${deviceToken}` } }; let ok = false;
  mw(okReq, fakeRes(), () => { ok = true; });
  assert.ok(ok && okReq.device.userId === 'u1' && okReq.device.orgId === 'o1');
  assert.ok(db.prepare('SELECT last_used FROM device_tokens').get().last_used);
  for (const h of [{ authorization: 'Bearer nope' }, {}, { authorization: deviceToken }]) {
    const bad = fakeRes(); let called = false;
    mw({ headers: h }, bad, () => { called = true; });
    assert.equal(bad.statusCode, 401); assert.equal(called, false);
  }
});
