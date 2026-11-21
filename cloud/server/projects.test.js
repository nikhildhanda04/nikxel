import test from 'node:test';
import assert from 'node:assert/strict';
import { boot } from './testkit.js';

test('projects: create, membership, archive, feed, shares', async () => {
  const c = await boot(); const { api, db } = c;
  db.prepare('INSERT INTO users VALUES (?,?,?,?,?)').run('memA3', 's3', 'm3@x.com', 'memA3', 1);
  db.prepare('INSERT INTO memberships VALUES (?,?,?)').run('memA3', 'A', 'member');
  const h = (u, r = 'member', o = 'A') => c.cookie(u, o, r);
  const mk = (u, name) => api('POST', '/api/projects', { headers: h(u), body: { name } });

  const p = await mk('memA', 'Produce PS');
  assert.equal(p.status, 200);
  const id = p.json.id;
  assert.equal((await mk('memA2', 'produce ps')).status, 409);
  assert.equal((await mk('memA2', 'x'.repeat(81))).status, 400);

  const put = (u, t, r = 'member') => api('PUT', `/api/projects/${id}/members/${t}`, { headers: h(u, r) });
  assert.equal((await put('memA', 'memA2')).status, 200);
  assert.equal((await put('memA', 'owB')).status, 400);
  const patch = (u, body, r = 'member') => api('PATCH', `/api/projects/${id}`, { headers: h(u, r), body });
  assert.equal((await patch('memA3', { name: 'Hax' })).status, 403);
  assert.equal((await api('GET', `/api/projects/${id}`, { headers: h('memA3') })).json.project.can_edit, false);
  assert.equal((await api('GET', `/api/projects/${id}`, { headers: h('memA3') })).status, 200);
  assert.equal((await api('PUT', `/api/projects/${id}/members/memA3`, { headers: h('memA3') })).status, 403);

  // sent days
  const dev = c.deviceFor('memA', 'A'), dev3 = c.deviceFor('memA3', 'A');
  const day = (date, items) => api('POST', '/api/summaries', { headers: dev, body: { kind: 'day', date, headline: '', items } });
  const item = (i, project) => ({ id: i, section: 's', project, what: 'w' + i, type: 'coding', minutes: 5, details: [] });
  assert.equal((await day('2026-11-20', [item('a', 'PRODUCE ps'), item('b', 'Nope')])).status, 200);
  let g = (await api('GET', `/api/projects/${id}`, { headers: h('memA3') })).json;
  assert.equal(g.days.length, 1);
  assert.deepEqual(g.days[0].items.map((i) => [i.id, i.name, i.user_id]), [['a', 'memA', 'memA']]);
  assert.equal((await patch('memA', { name: 'PPS' })).status, 200);
  g = (await api('GET', `/api/projects/${id}`, { headers: h('memA3') })).json;
  assert.equal(g.days[0].items.length, 1);
  assert.equal(g.project.name, 'PPS');
  assert.equal((await patch('memA', { name: 'pps' })).status, 200); // own name, case change
  assert.equal((await mk('memA2', 'Other')).status, 200);
  assert.equal((await patch('memA', { name: 'OTHER' })).status, 409);

  // meeting shares
  const share = (d, pid, body) => api('POST', `/api/projects/${pid}/meetings`, { headers: d, body });
  const m = (b) => ({ meeting_id: '2026-11-21-1030', title: 'Sync', date: '2026-11-21', body: b });
  assert.equal((await share(dev, id, m('one'))).status, 200);
  assert.equal((await share(dev, id, m('two'))).status, 200);
  g = (await api('GET', `/api/projects/${id}`, { headers: h('memA3') })).json;
  assert.equal(g.days[0].date, '2026-11-21');
  assert.deepEqual(g.days[0].meetings.map((x) => [x.body, x.name]), [['two', 'memA']]);
  assert.equal((await share(dev3, id, m('x'))).status, 404);
  assert.equal((await share(c.deviceFor('owB', 'B'), id, m('x'))).status, 404);
  assert.equal((await share(dev, id, m('x'.repeat(20001)))).status, 400);
  assert.equal((await share(dev, id, { ...m('x'), meeting_id: 'a/b' })).status, 400);
  assert.equal(db.prepare('SELECT COUNT(*) n FROM meeting_shares').get().n, 1);

  // org B cannot see it
  assert.equal((await api('GET', `/api/projects/${id}`, { headers: h('owB', 'owner', 'B') })).status, 404);

  // list + device list
  const l = (await api('GET', '/api/projects', { headers: h('memA3') })).json;
  assert.deepEqual(l.map((x) => x.name), ['pps', 'Other']);
  assert.equal(l[0].last_activity, '2026-11-21');
  assert.deepEqual(l[0].members.map((x) => x.user_id).sort(), ['memA', 'memA2']);
  assert.deepEqual((await api('GET', '/api/device/projects', { headers: dev })).json.map((x) => x.name), ['pps']);

  // archive (admin, not a member)
  assert.equal((await patch('admA', { archived: true }, 'admin')).status, 200);
  assert.deepEqual((await api('GET', '/api/projects', { headers: h('memA3') })).json.map((x) => x.name), ['Other']);
  assert.equal((await api('GET', `/api/projects/${id}`, { headers: h('memA3') })).json.project.archived, true);
  assert.deepEqual((await api('GET', '/api/device/projects', { headers: dev })).json, []);
  assert.equal((await share(dev, id, m('x'))).status, 404);
  assert.equal((await day('2026-11-22', [item('z', 'pps')])).status, 200); // archived: never linked
  assert.equal(JSON.parse(db.prepare("SELECT items FROM summaries WHERE user_id='memA' AND date='2026-11-22'").get().items)[0].project_id, null);
  c.close();
});
