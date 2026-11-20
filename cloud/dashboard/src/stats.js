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
  return [...out.values()].filter((e) => e.minutes > 0); // 0-minute days (ERP-task-only) would give the chart a 0 max
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
    .map((p) => ({ ...p, tasks: p.tasks.size, items: p.items.sort((a, b) => b.date.localeCompare(a.date)), people: [...p.people].map(([name, minutes]) => ({ name, minutes })).sort(desc) }))
    .sort((a, b) => (a.project === NO_PROJECT) - (b.project === NO_PROJECT) || desc(a, b) || a.project.localeCompare(b.project));
}

export function typeTotals(rows) {
  const t = {};
  for (const r of rows) for (const i of r.items || []) if (i.minutes > 0) t[typeOf(i.type)] = (t[typeOf(i.type)] || 0) + i.minutes;
  return Object.entries(t).map(([type, minutes]) => ({ type, minutes })).sort(desc);
}

export const OTHERS = 'Others';
// Chart series slot i -> color; index.css defines --s-1..--s-5, anything past them is gray like Others.
export const seriesColor = (i) => (i < 5 ? `var(--s-${i + 1})` : 'var(--t-other)');

// [{label, minutes}] -> top (max-1) + Others, each with a whole-number pct; pcts sum to 100 (largest remainder).
// An entry already labelled Others always joins the fold, so Others is one slice, last.
export function pieSlices(totals, max = 6) {
  const t = totals.filter((x) => x.minutes > 0 && x.label !== OTHERS).sort(desc);
  const given = totals.filter((x) => x.minutes > 0 && x.label === OTHERS);
  const keep = t.length + (given.length ? 1 : 0) <= max ? t.length : max - 1;
  const rest = [...t.slice(keep), ...given];
  const s = rest.length ? [...t.slice(0, keep), { ...given[0], label: OTHERS, minutes: rest.reduce((n, x) => n + x.minutes, 0) }] : t;
  const sum = s.reduce((n, x) => n + x.minutes, 0);
  const out = s.map((x) => ({ ...x, pct: Math.floor((x.minutes / sum) * 100), r: ((x.minutes / sum) * 100) % 1 }));
  let left = 100 - out.reduce((n, x) => n + x.pct, 0);
  for (const x of [...out].sort((a, b) => b.r - a.r)) if (left-- > 0) x.pct++;
  return out.map(({ r, ...x }) => x);
}

// Minutes per person per calendar day over `days` days ending at the newest date: [{id, name, total, points}],
// biggest total first; past topN the rest fold into one Others series.
export function lineSeries(rows, days, topN = 5) {
  const data = byPersonDay(rows, days);
  if (!data.length) return [];
  const range = dayRange(rows.reduce((d, r) => (r.date > d ? r.date : d), ''), days); // same window as byPersonDay
  const people = new Map();
  for (const d of data) {
    if (!people.has(d.user_id)) people.set(d.user_id, { id: d.user_id, name: d.name, total: 0, points: Array(days).fill(0) });
    const p = people.get(d.user_id);
    p.total += d.minutes;
    p.points[range.indexOf(d.date)] += d.minutes;
  }
  const s = [...people.values()].sort((a, b) => desc({ minutes: a.total }, { minutes: b.total }) || a.name.localeCompare(b.name));
  if (s.length <= topN) return s;
  const rest = s.slice(topN);
  return [...s.slice(0, topN), { id: OTHERS, name: OTHERS, total: rest.reduce((n, x) => n + x.total, 0), points: range.map((_, i) => rest.reduce((n, x) => n + x.points[i], 0)) }];
}
