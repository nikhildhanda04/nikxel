// Pure helpers for the Org tab. Plain JS so node --test can import it.

// which: 'all' | 'joined' | 'not'
export function filterPeople(people, q, which) {
  const s = q.trim().toLowerCase();
  return people.filter((p) => (which === 'all' || p.joined === (which === 'joined'))
    && (!s || [p.name, p.email, p.title].some((v) => v && v.toLowerCase().includes(s))));
}

const SHOW = {
  active: (p) => !p.archived && p.active,
  inactive: (p) => !p.archived && !p.active, // inactive in the ERP, not archived by hand
  archived: (p) => p.archived,
  all: () => true,
};
// which: 'active' | 'inactive' | 'archived' | 'all'. Drops removed members, leads first (stable by name otherwise).
export function teamCards(projects, which) {
  return projects.filter(SHOW[which])
    .map((p) => ({ ...p, members: p.members.filter((m) => !m.removed).sort((a, b) => (b.role === 'lead') - (a.role === 'lead')) }));
}
