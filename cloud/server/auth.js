import crypto from 'node:crypto';
import { OAuth2Client } from 'google-auth-library';

const COOKIE = 'nikxel_session';
const mac = (body, secret) => crypto.createHmac('sha256', secret).update(body).digest();

export function signCookie(payload, secret) {
  const body = Buffer.from(JSON.stringify(payload)).toString('base64url');
  return `${body}.${mac(body, secret).toString('base64url')}`;
}

export function verifyCookie(value, secret) {
  if (typeof value !== 'string') return null;
  const parts = value.split('.');
  if (parts.length !== 2) return null;
  const [body, sig] = parts;
  const given = Buffer.from(sig, 'base64url');
  const want = mac(body, secret);
  if (given.length !== want.length || !crypto.timingSafeEqual(given, want)) return null;
  // canonical-encoding check: reject non-canonical base64url variants of a valid MAC
  if (given.toString('base64url') !== sig) return null;
  try { return JSON.parse(Buffer.from(body, 'base64url').toString()); } catch { return null; }
}

export function issueSession(res, { userId, orgId, role }, secret) {
  res.cookie(COOKIE, signCookie({ userId, orgId, role }, secret),
    { httpOnly: true, sameSite: 'lax', secure: true, path: '/', maxAge: 7 * 24 * 3600 * 1000 });
}

export function readSession(req, secret) {
  const raw = (req.headers?.cookie || '').split(/;\s*/).find((c) => c.startsWith(COOKIE + '='));
  if (!raw) return null;
  const p = verifyCookie(raw.slice(COOKIE.length + 1), secret);
  return p && { userId: p.userId, orgId: p.orgId, role: p.role };
}

export const requireRole = (...roles) => (req, res, next) => {
  const s = readSession(req, process.env.SESSION_SECRET);
  if (!s) return res.status(401).json({ error: 'unauthenticated' });
  if (!roles.includes(s.role)) return res.status(403).json({ error: 'forbidden' });
  req.session = s;
  next();
};

async function defaultVerifier(idToken, clientId) {
  const ticket = await new OAuth2Client(clientId).verifyIdToken({ idToken, audience: clientId });
  return ticket.getPayload();
}

export async function verifyGoogle(idToken, clientId, verifier = defaultVerifier) {
  const { sub, email, name } = await verifier(idToken, clientId);
  return { sub, email, name };
}
