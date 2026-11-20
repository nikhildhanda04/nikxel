import test from 'node:test';
import assert from 'node:assert/strict';
import { signCookie, verifyCookie, verifyGoogle, requireRole, assertSecret, issueSession, readSession } from './auth.js';

const S = 'test-secret-0123456789';
const fakeRes = () => ({
  statusCode: 200, headers: {}, body: undefined,
  status(c) { this.statusCode = c; return this; },
  json(b) { this.body = b; return this; },
  cookie(name, value, opts) { this.headers.cookie = { name, value, opts }; return this; },
});
const fakeReqWithSession = (s, secret = S) => {
  const res = fakeRes();
  issueSession(res, { userId: 'u1', orgId: 'o1', ...s }, secret);
  return { headers: { cookie: `${res.headers.cookie.name}=${res.headers.cookie.value}` } };
};

test('signed cookie round-trips and rejects tampering', () => {
  const v = signCookie({userId:'u1',orgId:'o1',role:'owner'}, S);
  assert.deepEqual(verifyCookie(v,S), {userId:'u1',orgId:'o1',role:'owner'});
  assert.equal(verifyCookie(v+'x',S), null);
  assert.equal(verifyCookie(v,'a-different-secret-xyz'), null);
});
test('verifyCookie returns null on garbage', () => {
  for (const g of ['', 'abc', '.', 'a.b', 'a.b.c', null, undefined, 42])
    assert.equal(verifyCookie(g, S), null);
});
test('verifyGoogle uses the injected verifier', async () => {
  const fake = async (tok) => ({sub:'g1', email:'a@b.com', name:'A', email_verified:true});
  assert.deepEqual(await verifyGoogle('tok','cid',fake), {sub:'g1',email:'a@b.com',name:'A'});
});
test('issueSession sets secure httpOnly lax cookie; readSession reads it', () => {
  const res = fakeRes();
  issueSession(res, {userId:'u1',orgId:'o1',role:'admin'}, S);
  const { opts } = res.headers.cookie;
  assert.equal(opts.httpOnly, true); assert.equal(opts.secure, true); assert.equal(opts.sameSite, 'lax');
  assert.deepEqual(readSession(fakeReqWithSession({role:'admin'}), S), {userId:'u1',orgId:'o1',role:'admin'});
  assert.equal(readSession({headers:{}}, S), null);
});
const fakeDb = (role) => ({ prepare: () => ({ get: () => ({ org_id: 'o1', role }) }) });
test('requireRole denies wrong role', () => {
  process.env.SESSION_SECRET = S;
  const mw = requireRole(fakeDb('member'), 'owner','admin');
  const res = fakeRes(); let nexted=false;
  mw(fakeReqWithSession({role:'member'}), res, ()=>{nexted=true});
  assert.equal(res.statusCode, 403); assert.equal(nexted, false);
});
test('requireRole 401 without session, passes allowed role', () => {
  process.env.SESSION_SECRET = S;
  const mw = requireRole(fakeDb('owner'), 'owner');
  const res = fakeRes(); let nexted=false;
  mw({headers:{}}, res, ()=>{nexted=true});
  assert.equal(res.statusCode, 401); assert.equal(nexted, false);
  const req = fakeReqWithSession({role:'owner'}); const res2 = fakeRes();
  mw(req, res2, ()=>{nexted=true});
  assert.equal(nexted, true); assert.equal(req.session.role, 'owner');
});

test('secret guard: bad secrets fail closed / throw', () => {
  const v = signCookie({userId:'u1'}, S);
  for (const bad of ['', 'short', undefined]) {
    assert.equal(verifyCookie(v, bad), null);
    assert.throws(() => signCookie({userId:'u1'}, bad));
    assert.throws(() => assertSecret(bad));
  }
  assertSecret(S);
});
test('expired cookie verifies to null; issued cookie carries future exp', () => {
  assert.equal(verifyCookie(signCookie({userId:'u1', exp: Date.now()-1000}, S), S), null);
  const res = fakeRes(); issueSession(res, {userId:'u1',orgId:'o1',role:'owner'}, S);
  const p = verifyCookie(res.headers.cookie.value, S);
  assert.ok(p.exp > Date.now());
});
test('verifyGoogle rejects unverified email and empty payload', async () => {
  await assert.rejects(verifyGoogle('t','c', async () => ({sub:'g',email:'a@b.com',name:'A',email_verified:false})));
  await assert.rejects(verifyGoogle('t','c', async () => ({sub:'g',email:'a@b.com',name:'A'})));
  await assert.rejects(verifyGoogle('t','c', async () => null));
  assert.equal((await verifyGoogle('t','c', async () => ({sub:'g',email:'a@b.com',name:'A',email_verified:true}))).sub, 'g');
});
test('payload forgery with original MAC is rejected', () => {
  const [body, sig] = signCookie({userId:'u1',orgId:'o1',role:'member'}, S).split('.');
  const forged = Buffer.from(JSON.stringify({userId:'u1',orgId:'o1',role:'owner'})).toString('base64url');
  assert.equal(verifyCookie(`${forged}.${sig}`, S), null);
  const flipped = (body[0] === 'A' ? 'B' : 'A') + body.slice(1);
  assert.equal(verifyCookie(`${flipped}.${sig}`, S), null);
});
