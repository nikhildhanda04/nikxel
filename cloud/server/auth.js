import crypto from 'node:crypto';
import { OAuth2Client } from 'google-auth-library';

const COOKIE = 'nikxel_session';
const mac = (body, secret) => crypto.createHmac('sha256', secret).update(body).digest();

const validSecret = (s) => typeof s === 'string' && s.length >= 16;
export function assertSecret(secret) {
  if (!validSecret(secret)) throw new Error('SESSION_SECRET must be a string of at least 16 characters');
}

export function signCookie(payload, secret) {
  assertSecret(secret);
  const body = Buffer.from(JSON.stringify(payload)).toString('base64url');
  return `${body}.${mac(body, secret).toString('base64url')}`;
}

export function verifyCookie(value, secret) {
  if (typeof value !== 'string' || !validSecret(secret)) return null;
  const parts = value.split('.');
  if (parts.length !== 2) return null;
  const [body, sig] = parts;
  const given = Buffer.from(sig, 'base64url');
  const want = mac(body, secret);
  if (given.length !== want.length || !crypto.timingSafeEqual(given, want)) return null;
  // canonical-encoding check: reject non-canonical base64url variants of a valid MAC
  if (given.toString('base64url') !== sig) return null;
  try {
    const p = JSON.parse(Buffer.from(body, 'base64url').toString());
    if (p && p.exp !== undefined && !(Date.now() <= p.exp)) return null;
    return p;
  } catch { return null; }
}

export function issueSession(res, { userId, orgId, role }, secret) {
  res.cookie(COOKIE, signCookie({ userId, orgId, role, exp: Date.now() + 7 * 24 * 3600 * 1000 }, secret),
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
  const p = await verifier(idToken, clientId);
  if (!p || p.email_verified !== true) throw new Error('Google email not verified');
  const { sub, email, name } = p;
  return { sub, email, name };
}
