import { test } from 'node:test';
import assert from 'node:assert/strict';
import { splitFeed, mdBlocks } from './feed.js';

const days = [
  { date: '2026-11-20', meetings: [{ id: 'm1', title: 'Sync' }], items: [{ id: 'a', section: 'what you worked on' }, { id: 'b', section: 'meetings' }] },
  { date: '2026-11-19', meetings: [{ id: 'm2', title: 'Retro' }], items: [] },
];

test('splitFeed meetings keeps shares and meetings-section items', () => {
  const r = splitFeed(days, 'meetings');
  assert.deepEqual(r.map((d) => d.date), ['2026-11-20', '2026-11-19']);
  assert.deepEqual(r[0].items.map((i) => i.id), ['b']);
  assert.equal(r[0].meetings.length, 1);
});

test('splitFeed work drops a meeting-only day and all meetings', () => {
  const r = splitFeed(days, 'work');
  assert.deepEqual(r.map((d) => d.date), ['2026-11-20']);
  assert.deepEqual(r[0].items.map((i) => i.id), ['a']);
  assert.deepEqual(r[0].meetings, []);
});

test('mdBlocks classifies lines', () => {
  assert.deepEqual(mdBlocks('## Decisions\n- Ship Friday\ntext'), [
    { kind: 'h', text: 'Decisions' }, { kind: 'li', text: 'Ship Friday' }, { kind: 'p', text: 'text' }]);
});

test('mdBlocks keeps html as literal text', () => {
  assert.deepEqual(mdBlocks('<img src=x onerror=alert(1)>'), [{ kind: 'p', text: '<img src=x onerror=alert(1)>' }]);
});
