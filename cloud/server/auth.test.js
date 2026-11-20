import test from 'node:test';
import assert from 'node:assert/strict';
import { signCookie, verifyCookie, verifyGoogle, requireRole, issueSession, readSession } from './auth.js';

const fakeRes = () => ({
  statusCode: 200, headers: {}, body: undefined,
  status(c) { this.statusCode = c; return this; },
  json(b) { this.body = b; return this; },
  cookie(name, value, opts) { this.headers.cookie = { name, value, opts }; return this; },
});
const fakeReqWithSession = (s, secret = 'secret') => {
  const res = fakeRes();
  issueSession(res, { userId: 'u1', orgId: 'o1', ...s }, secret);
  return { headers: { cookie: `${res.headers.cookie.name}=${res.headers.cookie.value}` } };
};

test('signed cookie round-trips and rejects tampering', () => {
  const v = signCookie({userId:'u1',orgId:'o1',role:'owner'}, 'secret');
  assert.deepEqual(verifyCookie(v,'secret'), {userId:'u1',orgId:'o1',role:'owner'});
  assert.equal(verifyCookie(v+'x','secret'), null);
  assert.equal(verifyCookie(v,'wrong'), null);
});
test('verifyCookie returns null on garbage', () => {
  for (const g of ['', 'abc', '.', 'a.b', 'a.b.c', null, undefined, 42])
    assert.equal(verifyCookie(g, 'secret'), null);
});
test('verifyGoogle uses the injected verifier', async () => {
  const fake = async (tok) => ({sub:'g1', email:'a@b.com', name:'A'});
  assert.deepEqual(await verifyGoogle('tok','cid',fake), {sub:'g1',email:'a@b.com',name:'A'});
});
test('issueSession sets secure httpOnly lax cookie; readSession reads it', () => {
  const res = fakeRes();
  issueSession(res, {userId:'u1',orgId:'o1',role:'admin'}, 'secret');
  const { opts } = res.headers.cookie;
  assert.equal(opts.httpOnly, true); assert.equal(opts.secure, true); assert.equal(opts.sameSite, 'lax');
  assert.deepEqual(readSession(fakeReqWithSession({role:'admin'}), 'secret'), {userId:'u1',orgId:'o1',role:'admin'});
  assert.equal(readSession({headers:{}}, 'secret'), null);
});
test('requireRole denies wrong role', () => {
  process.env.SESSION_SECRET = 'secret';
  const mw = requireRole('owner','admin');
  const res = fakeRes(); let nexted=false;
  mw(fakeReqWithSession({role:'member'}), res, ()=>{nexted=true});
  assert.equal(res.statusCode, 403); assert.equal(nexted, false);
});
test('requireRole 401 without session, passes allowed role', () => {
  process.env.SESSION_SECRET = 'secret';
  const mw = requireRole('owner');
  const res = fakeRes(); let nexted=false;
  mw({headers:{}}, res, ()=>{nexted=true});
  assert.equal(res.statusCode, 401); assert.equal(nexted, false);
  const req = fakeReqWithSession({role:'owner'}); const res2 = fakeRes();
  mw(req, res2, ()=>{nexted=true});
  assert.equal(nexted, true); assert.equal(req.session.role, 'owner');
});
