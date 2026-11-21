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

test('table columns match the spec exactly', () => {
  const db = openDb(':memory:'); bootstrap(db);
  const want = {
    users: ['id','google_sub','email','name','created_at'],
    orgs: ['id','name','owner_user_id','created_at'],
    memberships: ['user_id','org_id','role'],
    invites: ['id','org_id','token','role','created_at','accepted_by'],
    device_tokens: ['id','user_id','org_id','token_hash','created_at','last_used'],
    pairing_codes: ['code','user_id','org_id','expires_at'],
    summaries: ['id','user_id','org_id','kind','date','items','notes','visibility','status','created_at'],
  };
  for (const [t, cols] of Object.entries(want))
    assert.deepStrictEqual(db.prepare(`PRAGMA table_info(${t})`).all().map(r => r.name).sort(), [...cols].sort(), t);
});

test('bootstrap drops the old ERP org tables', () => {
  const db = openDb(':memory:');
  db.exec('CREATE TABLE org_people (id TEXT); CREATE TABLE org_projects (id TEXT); CREATE TABLE project_members (project_id TEXT)');
  bootstrap(db);
  const names = db.prepare("SELECT name FROM sqlite_master WHERE type='table'").all().map(r => r.name);
  for (const t of ['org_people', 'org_projects', 'project_members']) assert.ok(!names.includes(t), t);
  for (const t of ['projects', 'project_users', 'meeting_shares']) assert.ok(names.includes(t), t);
});
