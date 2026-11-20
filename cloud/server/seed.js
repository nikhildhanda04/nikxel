// Dev seed: node seed.js  (idempotent; DB_PATH defaults to ./dev.db)
import { openDb, bootstrap } from './db.js';

const db = openDb(process.env.DB_PATH || new URL('./dev.db', import.meta.url).pathname);
bootstrap(db);
const now = Date.now();
const ORG = 'dev-org';
const people = [['dev-jake', 'Jake', 'owner'], ['dev-asha', 'Asha', 'admin'], ['dev-ben', 'Ben', 'member'], ['dev-cleo', 'Cleo', 'member']];
const it = (id, section, what, type, minutes, details = []) => ({ id, section, what, type, minutes, details });
const days = {
  'dev-jake': [['2026-11-19', 'Pairing review and dashboard screens', [it('a', 'Nikxel', 'Reviewed pairing flow', 'review', 45, ['Checked code expiry']), it('b', 'Dashboard', 'Wrote dashboard screens', 'coding', 120, ['Rollup table', 'Role gating']), it('c', 'Nikxel', 'Fixed session expiry bug', 'shipped', 30)]],
               ['2026-11-20', 'Dev tooling day', [it('a', 'Dashboard', 'Seed script for dev', 'coding', 40), it('b', 'Dashboard', 'Vite proxy setup', 'coding', 25), it('c', 'Dashboard', 'Tailwind styling pass', 'writing', 60)]]],
  'dev-asha': [['2026-11-19', 'Onboarding and support', [it('a', 'Customers', 'Customer onboarding calls', 'meeting', 90), it('b', 'Docs', 'Updated invite docs', 'writing', 35), it('c', 'Support', 'Triage support inbox', 'comms', 50)]],
               ['2026-11-20', 'Roadmap planning', [it('a', 'Roadmap', 'Plan Q4 roadmap', 'planning', 75, ['Draft milestones']), it('b', 'Nikxel', 'Review PRs', 'review', 40), it('c', 'Website', 'Pricing page copy', 'writing', 55)]]],
  'dev-ben': [['2026-11-19', 'CSV export shipped', [it('a', 'Export', 'Implemented CSV export', 'shipped', 100, ['Streaming writer']), it('b', 'Export', 'Wrote unit tests', 'coding', 60), it('c', 'Nikxel', 'Code review', 'review', 30), it('d', 'Team', 'Standup notes', 'meeting', 10)]],
              ['2026-11-20', 'Sync debugging', [it('a', 'Sync', 'Refactor summary sync', 'coding', 85), it('b', 'Sync', 'Debug sync failure', 'research', 50, ['Traced retry loop']), it('c', 'Docs', 'Update changelog', 'writing', 20)]]],
  'dev-cleo': [['2026-11-19', 'Design and research', [it('a', 'Design', 'Designed empty states', 'other', 70), it('b', 'Research', 'User interview synthesis', 'learning', 80), it('c', 'Design', 'Icon cleanup', 'other', 25)]]],
};
db.transaction(() => {
  db.prepare('INSERT OR IGNORE INTO orgs VALUES (?,?,?,?)').run(ORG, 'Nikxel Dev', 'dev-jake', now);
  for (const [id, name, role] of people) {
    db.prepare('INSERT OR IGNORE INTO users VALUES (?,?,?,?,?)').run(id, 'sub-' + id, id + '@dev.local', name, now);
    db.prepare('INSERT OR IGNORE INTO memberships VALUES (?,?,?)').run(id, ORG, role);
    for (const [date, headline, items] of days[id] ?? [])
      db.prepare('INSERT OR IGNORE INTO summaries VALUES (?,?,?,?,?,?,?,?,?,?)').run(`${id}-day-${date}`, id, ORG, 'day', date,
        JSON.stringify(items), headline, 'admin', 'sent', now);
  }
})();
for (const [id, name, role] of people) console.log(id.padEnd(10), name.padEnd(6), role);
