import { test } from 'node:test';
import assert from 'node:assert';
import { cleanDay } from './summaries.js';

const it = (o = {}) => ({ id: 'a', section: 'S', what: 'w', type: 'coding', minutes: 5, details: [], ...o });
const day = (items, o = {}) => ({ date: '2026-11-20', headline: 'h', items, ...o });

test('cleanDay rejects bad date and long what', () => {
  assert.throws(() => cleanDay(day([it()], { date: '2026-13-99x' })), { status: 400 });
  assert.throws(() => cleanDay(day([it({ what: 'x'.repeat(1001) })])), { status: 400 });
});
test('cleanDay maps unknown type to other, trims details, keeps only wire keys', () => {
  const d = cleanDay(day([it({ type: 'gaming', secret: 1, details: [...Array(25).fill('d'), 7, null] })]));
  assert.equal(d.items[0].type, 'other');
  assert.equal(d.items[0].details.length, 20);
  assert.deepEqual(Object.keys(d.items[0]).sort(), ['details', 'id', 'minutes', 'section', 'type', 'what']);
  assert.deepEqual(cleanDay(day([it({ details: ['a', 1, 'b'] })])).items[0].details, ['a', 'b']);
});
