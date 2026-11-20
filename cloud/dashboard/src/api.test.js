import test from 'node:test';
import assert from 'node:assert/strict';
import { typeMeta, nextTheme } from './api.js';

test('typeMeta labels known types and falls back to Other', () => {
  assert.equal(typeMeta('coding').label, 'Coding');
  assert.equal(typeMeta('shipped').label, 'Shipped');
  assert.equal(typeMeta('nope').label, 'Other');
  for (const t of ['coding', 'shipped', 'meeting', 'research', 'learning', 'writing', 'review', 'planning', 'comms', 'other'])
    assert.ok(typeMeta(t).color && typeMeta(t).icon, t);
});

test('theme: nextTheme flips dark and light', () => {
  assert.equal(nextTheme('dark'), 'light');
  assert.equal(nextTheme('light'), 'dark');
});
