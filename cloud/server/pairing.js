import crypto from 'node:crypto';

const TTL = 10 * 60 * 1000;
const sha256 = (s) => crypto.createHash('sha256').update(s).digest('hex');

export function createPairingCode(db, userId, orgId, now = Date.now) {
  const ins = db.prepare('INSERT INTO pairing_codes (code, user_id, org_id, expires_at) VALUES (?,?,?,?)');
  for (let i = 0; i < 10; i++) {
    const code = String(crypto.randomInt(0, 1000000)).padStart(6, '0');
    try { ins.run(code, userId, orgId, now() + TTL); return code; }
    catch (e) { if (e.code !== 'SQLITE_CONSTRAINT_PRIMARYKEY') throw e; } // live-code collision: retry
  }
  throw new Error('could not allocate pairing code');
}

export function redeemPairingCode(db, code, now = Date.now) {
  return db.transaction(() => {
    const row = db.prepare('SELECT * FROM pairing_codes WHERE code = ?').get(String(code));
    if (!row) return null;
    db.prepare('DELETE FROM pairing_codes WHERE code = ?').run(row.code); // single-use, even if expired
    const t = now();
    if (row.expires_at <= t) return null;
    const deviceToken = crypto.randomBytes(32).toString('hex');
    db.prepare('INSERT INTO device_tokens (id, user_id, org_id, token_hash, created_at) VALUES (?,?,?,?,?)')
      .run(crypto.randomUUID(), row.user_id, row.org_id, sha256(deviceToken), t);
    return { deviceToken, userId: row.user_id, orgId: row.org_id };
  })();
}

export const deviceAuth = (db, now = Date.now) => (req, res, next) => {
  const m = /^Bearer ([0-9a-f]{64})$/.exec(req.headers?.authorization || '');
  const row = m && db.prepare('SELECT d.id, d.user_id, d.org_id FROM device_tokens d JOIN memberships m ON m.user_id = d.user_id AND m.org_id = d.org_id WHERE d.token_hash = ?').get(sha256(m[1]));
  if (!row) return res.status(401).json({ error: 'unauthorized' });
  db.prepare('UPDATE device_tokens SET last_used = ? WHERE id = ?').run(now(), row.id);
  req.device = { userId: row.user_id, orgId: row.org_id };
  next();
};
