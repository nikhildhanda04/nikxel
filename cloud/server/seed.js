// Dev seed: node seed.js  (idempotent; DB_PATH defaults to ./dev.db)
import { openDb, bootstrap } from './db.js';

const db = openDb(process.env.DB_PATH || new URL('./dev.db', import.meta.url).pathname);
bootstrap(db);
const now = Date.now();
const ORG = 'dev-org';
const people = [['dev-jake', 'Jake', 'owner'], ['dev-asha', 'Asha', 'admin'], ['dev-ben', 'Ben', 'member'], ['dev-cleo', 'Cleo', 'member']];
const W = 'what you worked on', M = 'meetings', B = 'browsing & reading', E = 'erp tasks';
const POS = 'Produce POS', NX = 'Nikxel', VL = 'Visual Lens';
const it = (id, section, what, type, minutes, project = '', details = []) => ({ id, section, what, type, minutes, details, project });
const erp = (id, what, project) => it(id, E, what, 'planning', 0, project);
const days = {
  'dev-jake': [
    ['2026-11-16', 'Pairing flow groundwork', [it('a', W, 'Pairing code endpoint', 'coding', 110, NX, ['Expiry and single use']), it('b', M, 'Weekly planning', 'meeting', 30, NX), it('c', B, 'Express 5 migration notes', 'research', 25), erp('e1', 'Pairing endpoint — In Progress (due 2026-11-24)', NX)]],
    ['2026-11-17', 'Session handling', [it('a', W, 'Signed session cookies', 'coding', 95, NX), it('b', W, 'Fixed session expiry bug', 'shipped', 35, NX), it('c', M, 'Produce POS sync', 'meeting', 40, POS)]],
    ['2026-11-18', 'POS receipts', [it('a', W, 'Receipt printer layout', 'coding', 130, POS, ['58mm paper']), it('b', W, 'Lens capture spike', 'research', 45, VL), it('c', B, 'ESC/POS docs', 'research', 20), erp('e1', 'Sign-out button — In Progress (due 2026-11-25)', POS)]],
    ['2026-11-19', 'Pairing review and dashboard screens', [it('a', W, 'Reviewed pairing flow', 'review', 45, NX, ['Checked code expiry']), it('b', W, 'Wrote dashboard screens', 'coding', 120, NX, ['Rollup table', 'Role gating']), it('c', W, 'Fixed session expiry bug', 'shipped', 30, NX), erp('e1', 'Sign-out button — Done', POS)]],
    ['2026-11-20', 'Dev tooling day', [it('a', W, 'Seed script for dev', 'coding', 40, NX), it('b', W, 'Vite proxy setup', 'coding', 25, NX), it('c', W, 'Tailwind styling pass', 'writing', 60, NX), it('d', M, 'Visual Lens demo', 'meeting', 35, VL), erp('e1', 'Dashboard charts — To Do (due 2026-11-27)', NX)]],
  ],
  'dev-asha': [
    ['2026-11-16', 'Roadmap prep', [it('a', W, 'Q4 roadmap outline', 'planning', 70, NX), it('b', M, 'Customer onboarding calls', 'meeting', 90, POS), it('c', W, 'Triage support inbox', 'comms', 40)]],
    ['2026-11-17', 'Support and docs', [it('a', W, 'Updated invite docs', 'writing', 35, NX), it('b', W, 'Triage support inbox', 'comms', 50), it('c', M, 'Visual Lens kickoff', 'meeting', 45, VL), erp('e1', 'Invite docs — Done', NX)]],
    ['2026-11-18', 'Lens requirements', [it('a', W, 'Lens requirements doc', 'writing', 100, VL), it('b', M, 'Produce POS sync', 'meeting', 40, POS), erp('e1', 'Lens requirements — In Progress (due 2026-11-26)', VL)]],
    ['2026-11-19', 'Onboarding and support', [it('a', M, 'Customer onboarding calls', 'meeting', 90, POS), it('b', W, 'Updated invite docs', 'writing', 35, NX), it('c', W, 'Triage support inbox', 'comms', 50), erp('e1', 'Onboarding checklist — In Progress (due 2026-11-23)', POS)]],
    ['2026-11-20', 'Roadmap planning', [it('a', W, 'Plan Q4 roadmap', 'planning', 75, NX, ['Draft milestones']), it('b', W, 'Review PRs', 'review', 40, NX), it('c', W, 'Pricing page copy', 'writing', 55), erp('e1', 'Onboarding checklist — Done', POS)]],
  ],
  'dev-ben': [
    ['2026-11-16', 'Export design', [it('a', W, 'CSV export design', 'planning', 60, POS), it('b', W, 'Export endpoint', 'coding', 90, POS), it('c', M, 'Standup', 'meeting', 10, NX)]],
    ['2026-11-17', 'Export progress', [it('a', W, 'Streaming writer', 'coding', 120, POS), it('b', W, 'Code review', 'review', 30, NX), erp('e1', 'CSV export — In Progress (due 2026-11-21)', POS)]],
    ['2026-11-18', 'Lens prototype', [it('a', W, 'Lens image pipeline', 'coding', 110, VL), it('b', B, 'OpenCV notes', 'research', 30), it('c', M, 'Standup', 'meeting', 10, NX)]],
    ['2026-11-19', 'CSV export shipped', [it('a', W, 'Implemented CSV export', 'shipped', 100, POS, ['Streaming writer']), it('b', W, 'Wrote unit tests', 'coding', 60, POS), it('c', W, 'Code review', 'review', 30, NX), it('d', M, 'Standup notes', 'meeting', 10, NX), erp('e1', 'CSV export — Done', POS)]],
    ['2026-11-20', 'Sync debugging', [it('a', W, 'Refactor summary sync', 'coding', 85, NX), it('b', W, 'Debug sync failure', 'research', 50, NX, ['Traced retry loop']), it('c', W, 'Update changelog', 'writing', 20), erp('e1', 'Sync retry fix — To Do (due 2026-11-22)', NX)]],
  ],
  'dev-cleo': [
    ['2026-11-16', 'Design system', [it('a', W, 'Color tokens', 'other', 90, NX), it('b', M, 'Design critique', 'meeting', 40, NX)]],
    ['2026-11-17', 'Lens research', [it('a', W, 'User interview synthesis', 'learning', 80, VL), it('b', B, 'Camera UX references', 'research', 35), erp('e1', 'Interview synthesis — In Progress (due 2026-11-24)', VL)]],
    ['2026-11-18', 'POS screens', [it('a', W, 'Checkout screen mockups', 'other', 120, POS), it('b', M, 'Produce POS sync', 'meeting', 40, POS), erp('e1', 'Checkout mockups — To Do (due 2026-11-25)', POS)]],
    ['2026-11-19', 'Design and research', [it('a', W, 'Designed empty states', 'other', 70, NX), it('b', W, 'User interview synthesis', 'learning', 80, VL), it('c', W, 'Icon cleanup', 'other', 25), erp('e1', 'Checkout mockups — In Progress (due 2026-11-25)', POS)]],
    ['2026-11-20', 'Lens polish', [it('a', W, 'Lens onboarding flow', 'other', 95, VL), it('b', M, 'Visual Lens demo', 'meeting', 35, VL), erp('e1', 'Interview synthesis — Done', VL)]],
  ],
};
db.transaction(() => {
  db.prepare('INSERT OR IGNORE INTO orgs VALUES (?,?,?,?)').run(ORG, 'Nikxel Dev', 'dev-jake', now);
  for (const [id, name, role] of people) {
    db.prepare('INSERT OR IGNORE INTO users VALUES (?,?,?,?,?)').run(id, 'sub-' + id, id + '@dev.local', name, now);
    db.prepare('INSERT OR IGNORE INTO memberships VALUES (?,?,?)').run(id, ORG, role);
    for (const [date, headline, items] of days[id] ?? [])
      db.prepare('INSERT OR REPLACE INTO summaries VALUES (?,?,?,?,?,?,?,?,?,?)').run(`${id}-day-${date}`, id, ORG, 'day', date,
        JSON.stringify(items), headline, 'admin', 'sent', now);
  }
})();
for (const [id, name, role] of people) console.log(id.padEnd(10), name.padEnd(6), role);
