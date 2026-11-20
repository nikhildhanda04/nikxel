import test from 'node:test';
import assert from 'node:assert/strict';
import { canEditFacts } from './api.js';

test('canEditFacts is owner-only', () => {
  assert.equal(canEditFacts('owner'), true);
  assert.equal(canEditFacts('admin'), false);
  assert.equal(canEditFacts('member'), false);
});
