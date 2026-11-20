import test from 'node:test';
import assert from 'node:assert/strict';
import { filterPeople, teamCards } from './orgView.js';

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
  { id: 'a', name: 'Alpha', archived: false, members: [
    { person_id: 'p2', name: 'Ben', role: 'member', removed: false },
    { person_id: 'p3', name: 'Cleo', role: 'member', removed: true },
    { person_id: 'p1', name: 'Asha', role: 'lead', removed: false },
  ] },
  { id: 'b', name: 'Beta', archived: true, members: [] },
];

test('teamCards: Active hides archived, Archived shows only them, All shows both', () => {
  assert.deepEqual(teamCards(projects, 'active').map((p) => p.id), ['a']);
  assert.deepEqual(teamCards(projects, 'archived').map((p) => p.id), ['b']);
  assert.deepEqual(teamCards(projects, 'all').map((p) => p.id), ['a', 'b']);
});

test('teamCards: excludes removed members and lists leads first', () => {
  assert.deepEqual(teamCards(projects, 'active')[0].members.map((m) => m.person_id), ['p1', 'p2']);
  assert.equal(projects[0].members.length, 3); // input untouched
});
