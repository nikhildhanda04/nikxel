import { test } from 'node:test';
import assert from 'node:assert';
import { openDb, bootstrap } from './db.js';

test('bootstrap creates tables and is idempotent', () => {
  const db = openDb(':memory:');
  bootstrap(db); bootstrap(db); // twice must not throw
  const names = db.prepare("SELECT name FROM sqlite_master WHERE type='table'").all().map(r => r.name);
  for (const t of ['users','orgs','memberships','invites','device_tokens','pairing_codes','summaries'])
    assert.ok(names.includes(t), `missing ${t}`);
});
test('summaries is unique per (user, org, kind, date)', () => {
  const db = openDb(':memory:'); bootstrap(db);
  const ins = db.prepare("INSERT INTO summaries(id,user_id,org_id,kind,date,items,notes,visibility,status,created_at) VALUES (?,?,?,?,?,?,?,?,?,?)");
  ins.run('a','u1','o1','work','2026-11-20','[]','','admin','pending',0);
  assert.throws(() => ins.run('b','u1','o1','work','2026-11-20','[]','','admin','pending',0));
});
