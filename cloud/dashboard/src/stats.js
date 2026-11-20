// Pure aggregation over api.rollup() rows ({date, user_id, name, items}). No React, so node --test can import it.
import { TYPE_ORDER } from './api.js';

export const NO_PROJECT = 'No project';
const pos = (m) => (m > 0 ? m : 0);
const typeOf = (t) => (TYPE_ORDER.includes(t) ? t : 'other'); // unknown types fold into Other, as on day cards
const desc = (a, b) => b.minutes - a.minutes;

// "Sync retry fix — To Do (due 2026-11-22)" -> [title, stage, due]
export const parseTask = (what) => {
  const m = /^(.*?)\s+[—–-]\s+([^—–]+?)(?:\s*\(due ([^)]+)\))?\.?$/.exec(what || '');
  return m ? [m[1], m[2], m[3] || ''] : [what || '', '', ''];
};

// n calendar days ending at `end` (YYYY-MM-DD), oldest first.
export const dayRange = (end, n) => Array.from({ length: n }, (_, i) => {
  const t = new Date(end + 'T00:00:00Z');
  t.setUTCDate(t.getUTCDate() - (n - 1 - i));
  return t.toISOString().slice(0, 10);
});

// Minutes per person per date, over the `days` calendar days ending at the newest date in rows.
export function byPersonDay(rows, days) {
  if (!rows.length) return [];
  const newest = rows.reduce((d, r) => (r.date > d ? r.date : d), '');
  const from = dayRange(newest, days)[0];
  const out = new Map();
  for (const r of rows) {
    if (r.date < from) continue;
    const k = r.user_id + '|' + r.date;
    if (!out.has(k)) out.set(k, { user_id: r.user_id, name: r.name || r.user_id, date: r.date, minutes: 0, byType: {} });
    const e = out.get(k);
    for (const i of r.items || []) {
      const m = pos(i.minutes);
      if (!m) continue;
      e.minutes += m;
      e.byType[typeOf(i.type)] = (e.byType[typeOf(i.type)] || 0) + m;
    }
  }
  return [...out.values()];
}

export function byProject(rows) {
  const out = new Map();
  for (const r of rows) for (const i of r.items || []) {
    const project = i.project || NO_PROJECT, name = r.name || r.user_id;
    if (!out.has(project)) out.set(project, { project, minutes: 0, people: new Map(), meetings: 0, tasks: new Set(), lastDate: '', items: [] });
    const p = out.get(project), m = pos(i.minutes);
    p.minutes += m;
    p.people.set(name, (p.people.get(name) || 0) + m);
    if (i.section === 'meetings') p.meetings++;
    if (i.section === 'erp tasks') p.tasks.add(parseTask(i.what)[0]); // a task recurs on every day it's touched
    if (r.date > p.lastDate) p.lastDate = r.date;
    p.items.push({ date: r.date, name, ...i });
  }
  return [...out.values()]
    .map((p) => ({ ...p, tasks: p.tasks.size, people: [...p.people].map(([name, minutes]) => ({ name, minutes })).sort(desc) }))
    .sort((a, b) => (a.project === NO_PROJECT) - (b.project === NO_PROJECT) || desc(a, b) || a.project.localeCompare(b.project));
}

export function typeTotals(rows) {
  const t = {};
  for (const r of rows) for (const i of r.items || []) if (i.minutes > 0) t[typeOf(i.type)] = (t[typeOf(i.type)] || 0) + i.minutes;
  return Object.entries(t).map(([type, minutes]) => ({ type, minutes })).sort(desc);
}
