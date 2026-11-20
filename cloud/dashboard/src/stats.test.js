import test from 'node:test';
import assert from 'node:assert/strict';
import { byPersonDay, byProject, typeTotals, dayRange, parseTask } from './stats.js';

const rows = [
  { date: '2026-11-20', user_id: 'a', name: 'Asha', items: [
    { id: 1, section: 'what you worked on', what: 'POS sync', type: 'coding', minutes: 120, project: 'Produce POS' },
    { id: 2, section: 'meetings', what: 'Standup', type: 'meeting', minutes: 30, project: 'Nikxel' },
    { id: 3, section: 'erp tasks', what: 'Sync retry fix — To Do (due 2026-11-22)', type: 'planning', minutes: 0, project: 'Produce POS' },
  ] },
  { date: '2026-11-20', user_id: 'b', name: 'Ben', items: [
    { id: 4, section: 'what you worked on', what: 'Dashboard', type: 'coding', minutes: 60, project: 'Nikxel' },
    { id: 5, section: 'other', what: 'Email', type: 'comms', minutes: 20, project: '' },
  ] },
  { date: '2026-11-19', user_id: 'a', name: 'Asha', items: [
    { id: 6, section: 'what you worked on', what: 'POS review', type: 'review', minutes: 45, project: 'Produce POS' },
  ] },
];

test('byProject: sorted by minutes, "" becomes No project last, counts meetings and tasks', () => {
  const p = byProject(rows);
  assert.deepEqual(p.map((x) => x.project), ['Produce POS', 'Nikxel', 'No project']);
  assert.deepEqual(p.map((x) => x.minutes), [165, 90, 20]);
  assert.deepEqual(p[0].people, [{ name: 'Asha', minutes: 165 }]);
  assert.deepEqual(p[1].people, [{ name: 'Ben', minutes: 60 }, { name: 'Asha', minutes: 30 }]);
  assert.equal(p[0].meetings, 0); assert.equal(p[0].tasks, 1);
  assert.equal(p[1].meetings, 1); assert.equal(p[1].tasks, 0);
  assert.equal(p[0].lastDate, '2026-11-20');
  assert.equal(p[0].items.length, 3);
  assert.deepEqual(Object.keys(p[0].items[0]).slice(0, 2), ['date', 'name']);
  assert.equal(p[0].items[0].name, 'Asha');
});

test('byProject: No project sorts last even when biggest', () => {
  const p = byProject([{ date: 'd', user_id: 'a', name: 'A', items: [
    { section: 'other', type: 'other', minutes: 500, project: '' },
    { section: 'other', type: 'other', minutes: 5, project: 'X' }] }]);
  assert.deepEqual(p.map((x) => x.project), ['X', 'No project']);
});

test('byPersonDay: minutes per person per date with byType', () => {
  const d = byPersonDay(rows, 14);
  const asha20 = d.find((x) => x.name === 'Asha' && x.date === '2026-11-20');
  assert.equal(asha20.minutes, 150);
  assert.deepEqual(asha20.byType, { coding: 120, meeting: 30 });
  assert.equal(d.find((x) => x.name === 'Asha' && x.date === '2026-11-19').minutes, 45);
  assert.equal(d.find((x) => x.name === 'Ben').minutes, 80);
  assert.equal(d.length, 3);
  assert.equal(byPersonDay(rows, 1).length, 2); // window ends at the newest date
});

test('typeTotals sums by type, biggest first', () => {
  assert.deepEqual(typeTotals(rows), [
    { type: 'coding', minutes: 180 }, { type: 'review', minutes: 45 },
    { type: 'meeting', minutes: 30 }, { type: 'comms', minutes: 20 }]);
});

test('empty input', () => {
  assert.deepEqual(byProject([]), []);
  assert.deepEqual(byPersonDay([], 14), []);
  assert.deepEqual(typeTotals([]), []);
});

test('dayRange: n calendar days ending at end, oldest first', () => {
  assert.deepEqual(dayRange('2026-11-02', 3), ['2026-10-31', '2026-11-01', '2026-11-02']);
});

test('ERP tasks: parsed, and counted once per project however many days mention them', () => {
  assert.deepEqual(parseTask('Sync retry fix — To Do (due 2026-11-22)'), ['Sync retry fix', 'To Do', '2026-11-22']);
  assert.deepEqual(parseTask('Onboarding checklist — Done'), ['Onboarding checklist', 'Done', '']);
  const t = { section: 'erp tasks', type: 'planning', minutes: 0, project: 'P' };
  const p = byProject([
    { date: '2026-11-20', user_id: 'a', name: 'A', items: [{ ...t, what: 'X — Done' }] },
    { date: '2026-11-19', user_id: 'a', name: 'A', items: [{ ...t, what: 'X — To Do (due 2026-11-22)' }, { ...t, what: 'Y — To Do' }] }]);
  assert.equal(p[0].tasks, 2);
});

test('byPersonDay: a window with only 0-minute items yields no entries (chart shows empty state)', () => {
  assert.deepEqual(byPersonDay([{ date: '2026-11-20', user_id: 'a', name: 'A', items: [
    { section: 'erp tasks', what: 'X — Done', type: 'planning', minutes: 0, project: 'P' }] }], 14), []);
});

test('byProject: items newest first regardless of row order', () => {
  const it = { section: 'other', type: 'other', minutes: 5, project: 'P' };
  const p = byProject([
    { date: '2026-11-18', user_id: 'a', name: 'A', items: [it] },
    { date: '2026-11-20', user_id: 'a', name: 'A', items: [it] }]);
  assert.deepEqual(p[0].items.map((i) => i.date), ['2026-11-20', '2026-11-18']);
});
