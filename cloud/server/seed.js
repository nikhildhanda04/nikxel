// Dev seed: node seed.js  (idempotent; DB_PATH defaults to ./dev.db)
import { openDb, bootstrap } from './db.js';

const db = openDb(process.env.DB_PATH || new URL('./dev.db', import.meta.url).pathname);
bootstrap(db);
const now = Date.now();
const ORG = 'dev-org';
const people = [['dev-jake', 'Jake', 'owner'], ['dev-asha', 'Asha', 'admin'], ['dev-ben', 'Ben', 'member'], ['dev-cleo', 'Cleo', 'member']];
const it = (id, what, minutes) => ({ id, what, minutes, removed: false });
const work = {
  'dev-jake': [['2026-11-19', 'released', [['a', 'Reviewed pairing flow', 45], ['b', 'Wrote dashboard screens', 120], ['c', 'Fixed session expiry bug', 30]]],
               ['2026-11-20', 'pending', [['a', 'Seed script for dev', 40], ['b', 'Vite proxy setup', 25], ['c', 'Tailwind styling pass', 60]]]],
  'dev-asha': [['2026-11-19', 'released', [['a', 'Customer onboarding calls', 90], ['b', 'Updated invite docs', 35], ['c', 'Triage support inbox', 50]]],
               ['2026-11-20', 'pending', [['a', 'Plan Q4 roadmap', 75], ['b', 'Review PRs', 40], ['c', 'Pricing page copy', 55]]]],
  'dev-ben': [['2026-11-19', 'released', [['a', 'Implemented CSV export', 100], ['b', 'Wrote unit tests', 60], ['c', 'Code review', 30], ['d', 'Standup notes', 10]]],
              ['2026-11-20', 'pending', [['a', 'Refactor summary merge', 85], ['b', 'Debug sync failure', 50], ['c', 'Update changelog', 20]]]],
  'dev-cleo': [['2026-11-19', 'released', [['a', 'Designed empty states', 70], ['b', 'User interview synthesis', 80], ['c', 'Icon cleanup', 25]]]],
};
db.transaction(() => {
  db.prepare('INSERT OR IGNORE INTO orgs VALUES (?,?,?,?)').run(ORG, 'Nikxel Dev', 'dev-jake', now);
  for (const [id, name, role] of people) {
    db.prepare('INSERT OR IGNORE INTO users VALUES (?,?,?,?,?)').run(id, 'sub-' + id, id + '@dev.local', name, now);
    db.prepare('INSERT OR IGNORE INTO memberships VALUES (?,?,?)').run(id, ORG, role);
    for (const [date, status, items] of work[id] ?? [])
      db.prepare('INSERT OR IGNORE INTO summaries VALUES (?,?,?,?,?,?,?,?,?,?)').run(`${id}-work-${date}`, id, ORG, 'work', date,
        JSON.stringify(items.map(([i, w, m]) => it(i, w, m))), '', 'admin', status, now);
  }
  db.prepare('INSERT OR IGNORE INTO summaries VALUES (?,?,?,?,?,?,?,?,?,?)').run('dev-ben-meeting', 'dev-ben', ORG, 'meeting', '2026-11-20',
    JSON.stringify([it('a', 'Weekly sync', 30)]), 'Agreed to ship dashboard v1 Friday. Ben owns export bug.', 'admin', 'pending', now);
})();
for (const [id, name, role] of people) console.log(id.padEnd(10), name.padEnd(6), role);
