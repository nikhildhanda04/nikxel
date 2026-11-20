import { test } from 'node:test';
import assert from 'node:assert/strict';
import { openDb, bootstrap } from './db.js';
import { importOrg, orgView, teamsFor, teamMemberUserIds } from './org.js';

function setup() {
  const db = openDb(':memory:'); bootstrap(db);
  for (const [u, o, r] of [['jake', 'O', 'owner'], ['asha', 'O', 'member'], ['ben', 'O', 'member'], ['out', 'X', 'owner']]) {
    db.prepare('INSERT INTO users VALUES (?,?,?,?,?)').run(u, 'sub-' + u, u + '@co.com', u, 1);
    db.prepare('INSERT INTO memberships VALUES (?,?,?)').run(u, o, r);
  }
  return db;
}
const P = (erp_id, name, email, o = {}) => ({ erp_id, name, email, title: 'Dev', manager_erp_id: null, note: '', ...o });
const body = (o = {}) => ({
  people: [P(1, 'Jake', 'JAKE@co.com'), P(2, 'Asha', 'asha@CO.com'), P(3, 'Ben', 'ben@co.com'), P(4, 'Nobody', 'nobody@co.com'), P(5, 'Out', 'out@co.com')],
  projects: [
    { erp_id: 10, name: 'Nikxel', description: 'd', active: true, members: [{ erp_id: 2, lead: true }, { erp_id: 3, lead: false }] },
    { erp_id: 11, name: 'POS', description: 'd', active: true, members: [{ erp_id: 3, lead: false }] },
  ],
  ...o,
});
const person = (db, erp) => db.prepare('SELECT * FROM org_people WHERE org_id = ? AND erp_id = ?').get('O', erp);
const project = (db, erp) => db.prepare('SELECT * FROM org_projects WHERE org_id = ? AND erp_id = ?').get('O', erp);
const member = (db, proj, pers) => db.prepare('SELECT * FROM project_members WHERE project_id = ? AND person_id = ?').get(project(db, proj).id, person(db, pers).id);

test('import creates people and projects, links users by email (org members only), idempotent', () => {
  const db = setup();
  importOrg(db, 'O', body());
  assert.equal(person(db, 1).user_id, 'jake');
  assert.equal(person(db, 2).user_id, 'asha');
  assert.equal(person(db, 4).user_id, null);
  assert.equal(person(db, 5).user_id, null); // user exists but in another org
  assert.equal(member(db, 10, 2).role, 'lead');
  const snap = () => JSON.stringify([db.prepare('SELECT * FROM org_people ORDER BY erp_id').all(), db.prepare('SELECT * FROM org_projects ORDER BY erp_id').all(), db.prepare('SELECT * FROM project_members ORDER BY project_id, person_id').all()]);
  const before = snap();
  importOrg(db, 'O', body());
  assert.equal(snap(), before);
  const v = orgView(db, 'O');
  assert.equal(v.people.length, 5);
  assert.equal(v.people.find((p) => p.erp_id === 1).joined, true);
  assert.equal(v.people.find((p) => p.erp_id === 4).joined, false);
  const nx = v.projects.find((p) => p.erp_id === 10);
  assert.deepEqual(Object.keys(nx).sort(), ['active', 'archived', 'description', 'erp_id', 'id', 'members', 'name']);
  assert.deepEqual(nx.members.map((m) => [m.name, m.role, m.removed, m.joined]), [['Asha', 'lead', false, true], ['Ben', 'member', false, true]]);
});

test('manual edits survive re-import; ERP fields still update', () => {
  const db = setup();
  importOrg(db, 'O', body());
  const nx = project(db, 10).id, pos = project(db, 11).id;
  db.prepare('UPDATE project_members SET removed = 1 WHERE project_id = ? AND person_id = ?').run(nx, person(db, 3).id);
  db.prepare("UPDATE org_projects SET name = 'Renamed', name_by_hand = 1 WHERE id = ?").run(nx);
  db.prepare('UPDATE org_projects SET archived = 1 WHERE id = ?').run(pos);
  db.prepare("UPDATE project_members SET role = 'member', role_by_hand = 1 WHERE project_id = ? AND person_id = ?").run(nx, person(db, 2).id);
  db.prepare("UPDATE org_people SET user_id = 'ben', linked_by_hand = 1 WHERE id = ?").run(person(db, 4).id);
  importOrg(db, 'O', body({
    people: [P(1, 'Jake', 'jake@co.com', { title: 'CTO' }), P(2, 'Asha', 'asha@co.com'), P(3, 'Ben', 'ben@co.com'), P(4, 'Nobody', 'nobody@co.com')],
    projects: [
      { erp_id: 10, name: 'Nikxel ERP', description: 'new', active: false, members: [{ erp_id: 2, lead: true }, { erp_id: 3, lead: true }, { erp_id: 1, lead: false }] },
      { erp_id: 11, name: 'POS', description: 'd', active: true, members: [] },
    ],
  }));
  assert.equal(member(db, 10, 3).removed, 1);
  assert.equal(project(db, 10).name, 'Renamed');
  assert.equal(project(db, 11).archived, 1);
  assert.equal(member(db, 10, 2).role, 'member');
  assert.equal(person(db, 4).user_id, 'ben');
  assert.equal(person(db, 1).title, 'CTO');
  assert.equal(project(db, 10).description, 'new');
  assert.equal(project(db, 10).active, 0);
  assert.equal(member(db, 10, 1).role, 'member'); // new member
  assert.equal(member(db, 11, 3), undefined); // dropped from ERP, not hand-edited
});

test('teamsFor and teamMemberUserIds', () => {
  const db = setup();
  importOrg(db, 'O', body());
  assert.deepEqual(teamsFor(db, 'O', 'jake', 'owner').map((t) => t.name), ['Nikxel', 'POS']);
  assert.deepEqual(teamsFor(db, 'O', 'asha', 'member').map((t) => t.name), ['Nikxel']);
  assert.deepEqual(teamsFor(db, 'O', 'ben', 'member'), []);
  db.prepare('UPDATE org_projects SET active = 0 WHERE erp_id = 10').run();
  assert.deepEqual(teamsFor(db, 'O', 'jake', 'owner').map((t) => [t.name, t.active]), [['Nikxel', false], ['POS', true]]);
  assert.deepEqual(teamsFor(db, 'O', 'asha', 'member').map((t) => t.active), [false]);
  db.prepare('UPDATE org_projects SET archived = 1 WHERE erp_id = 11').run();
  assert.deepEqual(teamsFor(db, 'O', 'jake', 'owner').map((t) => t.name), ['Nikxel']);
  assert.deepEqual(teamMemberUserIds(db, project(db, 10).id).sort(), ['asha', 'ben']);
});

test('import validates the body', () => {
  const db = setup();
  for (const b of [null, { people: 'x', projects: [] }, { people: [{ erp_id: 'a', name: 'x' }], projects: [] },
    { people: [], projects: [{ erp_id: 1, name: '', members: [] }] }, { people: Array(2001).fill(P(1, 'a', 'a@a')), projects: [] }])
    assert.throws(() => importOrg(db, 'O', b), (e) => e.status === 400);
  importOrg(db, 'O', { people: [P(1, 'x'.repeat(300), 'a@a', { note: 'n'.repeat(900) })], projects: [] });
  assert.equal(person(db, 1).name.length, 200);
  assert.equal(person(db, 1).note.length, 500);
});
