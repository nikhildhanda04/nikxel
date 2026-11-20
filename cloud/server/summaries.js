// Pure summary validation. No DB.
export class ForbiddenError extends Error {
  constructor(msg = 'forbidden') { super(msg); this.name = 'ForbiddenError'; }
}

const TYPES = ['coding', 'shipped', 'meeting', 'research', 'learning', 'writing', 'review', 'planning', 'comms', 'other'];
const bad = (msg) => Object.assign(new Error(msg), { status: 400 });
const str = (v, max) => typeof v === 'string' && v.trim() !== '' && v.length <= max;

// Validate a pushed day; returns only the wire fields. Throws status 400.
export function cleanDay(body) {
  let { date, headline = '', items } = body ?? {};
  if (!/^\d{4}-\d{2}-\d{2}$/.test(date) || Number.isNaN(Date.parse(date))) throw bad('bad date');
  if (typeof headline !== 'string') throw bad('bad headline');
  headline = headline.slice(0, 1000);
  if (!Array.isArray(items) || items.length > 500) throw bad('bad items');
  return {
    date, headline,
    items: items.map((i) => {
      if (!i || typeof i !== 'object' || !str(i.id, 200) || typeof i.what !== 'string' || i.what.trim() === '') throw bad('bad item');
      if (typeof i.minutes !== 'number' || !Number.isFinite(i.minutes) || i.minutes < 0) throw bad('bad minutes');
      const section = typeof i.section === 'string' ? i.section.slice(0, 200) : '';
      const details = Array.isArray(i.details) ? i.details.filter((d) => typeof d === 'string').slice(0, 20).map((d) => d.slice(0, 1000)) : [];
      const project = typeof i.project === 'string' ? i.project.trim().slice(0, 200) : '';
      return { id: i.id, section, project, what: i.what.slice(0, 1000), type: TYPES.includes(i.type) ? i.type : 'other', minutes: i.minutes, details };
    }),
  };
}
