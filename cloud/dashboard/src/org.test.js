import test from 'node:test';
import assert from 'node:assert/strict';
import { filterPeople, teamCards, initials, teamSummary, orgStats, sortTeams, teamsOfPerson, nameList, tipPos } from './orgView.js';

const people = [
  { id: 'p1', name: 'Asha Rao', email: 'asha@x.com', title: 'Engineer', joined: true },
  { id: 'p2', name: 'Ben Ho', email: 'ben@x.com', title: 'Designer', joined: false },
  { id: 'p3', name: 'Cleo', email: '', title: null, joined: false },
];

test('filterPeople: matches name, email or title, case-insensitive', () => {
  assert.deepEqual(filterPeople(people, 'asha', 'all').map((p) => p.id), ['p1']);
  assert.deepEqual(filterPeople(people, 'BEN@X', 'all').map((p) => p.id), ['p2']);
  assert.deepEqual(filterPeople(people, 'designer', 'all').map((p) => p.id), ['p2']);
  assert.deepEqual(filterPeople(people, '  ', 'all').map((p) => p.id), ['p1', 'p2', 'p3']);
  assert.deepEqual(filterPeople(people, 'zzz', 'all'), []);
});

test('filterPeople: joined / not joined', () => {
  assert.deepEqual(filterPeople(people, '', 'joined').map((p) => p.id), ['p1']);
  assert.deepEqual(filterPeople(people, '', 'not').map((p) => p.id), ['p2', 'p3']);
  assert.deepEqual(filterPeople(people, 'ben', 'joined'), []);
});

const projects = [
  { id: 'a', name: 'Alpha', active: true, archived: false, members: [
    { person_id: 'p2', name: 'Ben', role: 'member', removed: false },
    { person_id: 'p3', name: 'Cleo', role: 'member', removed: true },
    { person_id: 'p1', name: 'Asha', role: 'lead', removed: false },
  ] },
  { id: 'b', name: 'Beta', active: true, archived: true, members: [] },
  { id: 'c', name: 'Gamma', active: false, archived: false, members: [] },
];

test('teamCards: Active = not archived and active in ERP; Inactive = not archived, inactive in ERP; Archived; All', () => {
  assert.deepEqual(teamCards(projects, 'active').map((p) => p.id), ['a']);
  assert.deepEqual(teamCards(projects, 'inactive').map((p) => p.id), ['c']);
  assert.deepEqual(teamCards(projects, 'archived').map((p) => p.id), ['b']);
  assert.deepEqual(teamCards(projects, 'all').map((p) => p.id), ['a', 'b', 'c']);
});

test('teamCards: excludes removed members and lists leads first', () => {
  assert.deepEqual(teamCards(projects, 'active')[0].members.map((m) => m.person_id), ['p1', 'p2']);
  assert.equal(projects[0].members.length, 3); // input untouched
});

test('initials: one or two uppercase letters, ? when empty', () => {
  assert.equal(initials('Shivay Sharan'), 'SS');
  assert.equal(initials('Aarib'), 'A');
  assert.equal(initials(''), '?');
  assert.equal(initials('  asha  rao  kumar '), 'AR');
});

test('teamSummary: drops removed members, leads first, count excludes removed', () => {
  const s = teamSummary(projects[0]);
  assert.deepEqual(s.members.map((m) => m.person_id), ['p1', 'p2']);
  assert.deepEqual(s.leads, ['Asha']);
  assert.equal(s.count, 2);
  assert.deepEqual([s.id, s.name, s.active, s.archived], ['a', 'Alpha', true, false]);
  assert.deepEqual(teamSummary({ id: 'z', name: 'Z', active: true, archived: false, members: [] }).leads, []);
});

const m = (person_id, role, removed = false) => ({ person_id, name: person_id, role, removed });
const org = {
  people: [{ id: 'p1', joined: true }, { id: 'p2', joined: false }, { id: 'p3', joined: true }],
  projects: [
    { id: 't1', name: 'One', active: true, archived: false, members: [m('p1', 'lead'), m('p2', 'member')] },
    { id: 't2', name: 'Two', active: true, archived: false, members: [m('p2', 'member')] },
    { id: 't3', name: 'Three', active: true, archived: false, members: [m('p3', 'lead', true), m('p1', 'member')] },
    { id: 't4', name: 'Four', active: true, archived: true, members: [] },
    { id: 't5', name: 'Five', active: false, archived: false, members: [] },
  ],
};

test('orgStats: active teams, active teams without a live lead, people, joined', () => {
  assert.deepEqual(orgStats(org), { activeTeams: 3, noLead: 2, people: 3, joined: 2 });
});

test('sortTeams: size = count desc then name; name = alphabetical ignoring case', () => {
  const c = (name, count) => ({ name, count });
  const cards = [c('bravo', 2), c('Zulu', 6), c('alpha', 2), c('Echo', 6)];
  assert.deepEqual(sortTeams(cards, 'size').map((x) => x.name), ['Echo', 'Zulu', 'alpha', 'bravo']);
  assert.deepEqual(sortTeams(cards, 'name').map((x) => x.name), ['alpha', 'bravo', 'Echo', 'Zulu']);
  assert.equal(cards[0].name, 'bravo'); // input untouched
});

test('teamCards: noLead keeps only teams without a live lead', () => {
  assert.deepEqual(teamCards(org.projects, 'active', { noLead: true }).map((p) => p.id), ['t2', 't3']);
  assert.deepEqual(teamCards(org.projects, 'active', {}).map((p) => p.id), ['t1', 't2', 't3']);
});

test('teamsOfPerson: skips archived teams and removed memberships, led teams first', () => {
  const ps = [
    { id: 'x', name: 'Xray', archived: false, members: [m('p1', 'member')] },
    { id: 'y', name: 'Yank', archived: false, members: [m('p1', 'lead')] },
    { id: 'z', name: 'Zed', archived: true, members: [m('p1', 'lead')] },
    { id: 'w', name: 'Whisky', archived: false, members: [m('p1', 'member', true)] },
    { id: 'v', name: 'Victor', archived: false, members: [m('p2', 'lead')] },
  ];
  assert.deepEqual(teamsOfPerson(ps, 'p1'), ['Yank', 'Xray']);
  assert.deepEqual(teamsOfPerson(ps, 'p9'), []);
});

test('nameList: comma list, capped with "and N more"', () => {
  assert.equal(nameList(['A']), 'A');
  assert.equal(nameList(['A', 'B', 'C']), 'A, B, C');
  const many = Array.from({ length: 13 }, (_, i) => 'n' + i);
  assert.equal(nameList(many), 'n0, n1, n2, n3, n4, n5, n6, n7, n8, n9 and 3 more');
  assert.equal(nameList(many.slice(0, 10)), many.slice(0, 10).join(', '));
});

test('tipPos: above and centered, clamped into the viewport, flips below when no room', () => {
  const r = (left, top, width = 20, height = 20) => ({ left, top, width, height, right: left + width, bottom: top + height });
  // room above: centered over the trigger, 6px gap
  assert.deepEqual(tipPos(r(100, 200), { width: 80, height: 30 }, 375), { left: 70, top: 164, below: false });
  // near the right edge: clamped to 375 - 8 - width
  assert.deepEqual(tipPos(r(350, 200), { width: 120, height: 30 }, 375), { left: 247, top: 164, below: false });
  // near the left edge
  assert.equal(tipPos(r(0, 200), { width: 120, height: 30 }, 375).left, 8);
  // no room above: below the trigger
  assert.deepEqual(tipPos(r(100, 10), { width: 80, height: 30 }, 375), { left: 70, top: 36, below: true });
});
