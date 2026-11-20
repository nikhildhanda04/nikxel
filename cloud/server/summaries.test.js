import { test } from 'node:test';
import assert from 'node:assert';
import { mergeItems, adminView, redact, ownerEdit, release, ForbiddenError } from './summaries.js';

test('mergeItems preserves removed flags on re-push', () => {
  const existing = [{id:'1',what:'A',minutes:60,removed:true},{id:'2',what:'B',minutes:30,removed:false}];
  const incoming = [{id:'1',what:'A',minutes:90,removed:false},{id:'2',what:'B',minutes:45},{id:'3',what:'C',minutes:15}];
  const out = mergeItems(existing, incoming);
  assert.equal(out.find(i=>i.id==='1').removed, true);   // stays redacted even if client sends removed:false
  assert.equal(out.find(i=>i.id==='1').minutes, 90);     // facts updated
  assert.equal(out.find(i=>i.id==='3').removed, false);  // new item visible
});
test('adminView hides pending and removed items', () => {
  assert.equal(adminView({status:'pending',items:[]}), null);
  const v = adminView({status:'released',items:[{id:'1',removed:true,what:'x',minutes:1},{id:'2',removed:false,what:'y',minutes:2}]});
  assert.deepEqual(v.items.map(i=>i.id), ['2']);
});
test('member cannot edit facts; owner can, only while pending', () => {
  const s = {status:'pending',items:[{id:'1',what:'A',minutes:60,removed:false}]};
  assert.throws(() => ownerEdit(s,'1',{minutes:999},'member'), ForbiddenError);
  ownerEdit(s,'1',{minutes:120},'owner');
  assert.equal(s.items[0].minutes, 120);
  const r = {status:'released',items:[{id:'1',what:'A',minutes:60,removed:false}]};
  assert.throws(() => ownerEdit(r,'1',{minutes:1},'owner'), ForbiddenError);
});
test('redact only while pending', () => {
  const s = {status:'pending',items:[{id:'1',removed:false,what:'A',minutes:1}]};
  redact(s,'1','member'); assert.equal(s.items[0].removed, true);
  assert.throws(() => redact({status:'released',items:[{id:'1',removed:false}]},'1','member'), ForbiddenError);
});
test('mergeItems adds a new item and preserves the existing one', () => {
  const merged = mergeItems([{id:'1',what:'A',minutes:1,removed:false}], [{id:'1',what:'A',minutes:1},{id:'2',what:'N',minutes:5}]);
  assert.equal(merged.length, 2);
  assert.equal(merged[0].id, '1'); // existing first, new appended
});
test('release is pending->released and idempotent', () => {
  const s = {status:'pending',items:[]};
  release(s,'owner'); assert.equal(s.status,'released');
  release(s,'owner'); assert.equal(s.status,'released');
});
test('ownerEdit ignores fields other than what/minutes', () => {
  const s = {status:'pending',items:[{id:'1',what:'A',minutes:1,removed:true}]};
  ownerEdit(s,'1',{removed:false,id:'x',minutes:2},'owner');
  assert.equal(s.items[0].removed, true); assert.equal(s.items[0].id,'1'); assert.equal(s.items[0].minutes,2);
});
