import test from 'node:test';
import assert from 'node:assert/strict';
import { STAFF, isStaff, roleLabel, assignableRoles } from './roles.js';

test('roleLabel', () => {
  assert.equal(roleLabel('cofounder'), 'co-founder');
  for (const r of ['owner', 'admin', 'member']) assert.equal(roleLabel(r), r);
});
test('isStaff', () => {
  assert.deepEqual(STAFF, ['owner', 'cofounder', 'admin']);
  for (const r of STAFF) assert.ok(isStaff(r), r);
  assert.ok(!isStaff('member') && !isStaff(undefined));
});
test('assignableRoles', () => {
  assert.deepEqual(assignableRoles('owner'), ['member', 'admin', 'cofounder']);
  assert.deepEqual(assignableRoles('admin'), ['member', 'admin']);
  assert.deepEqual(assignableRoles('cofounder'), ['member', 'admin']);
  assert.deepEqual(assignableRoles('member'), ['member']);
});
