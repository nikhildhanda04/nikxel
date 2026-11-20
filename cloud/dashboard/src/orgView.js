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
const live = (p) => p.members.filter((m) => !m.removed);
const hasLead = (p) => live(p).some((m) => m.role === 'lead');

// which: 'active' | 'inactive' | 'archived' | 'all'. Drops removed members, leads first (stable by name otherwise).
// noLead: only teams with no non-removed lead.
export function teamCards(projects, which, { noLead = false } = {}) {
  return projects.filter((p) => SHOW[which](p) && (!noLead || !hasLead(p)))
    .map((p) => ({ ...p, members: live(p).sort((a, b) => (b.role === 'lead') - (a.role === 'lead')) }));
}

export const initials = (name) => (name || '').trim().split(/\s+/).slice(0, 2).map((w) => w[0]).join('').toUpperCase() || '?';

export function teamSummary(p) {
  const members = live(p).sort((a, b) => (b.role === 'lead') - (a.role === 'lead'));
  return { id: p.id, name: p.name, leads: members.filter((m) => m.role === 'lead').map((m) => m.name),
    members: members.map(({ person_id, name }) => ({ person_id, name })), count: members.length, active: p.active, archived: p.archived };
}

export function orgStats(org) {
  const active = org.projects.filter(SHOW.active);
  return { activeTeams: active.length, noLead: active.filter((p) => !hasLead(p)).length,
    people: org.people.length, joined: org.people.filter((p) => p.joined).length };
}

const byName = (a, b) => a.name.localeCompare(b.name, undefined, { sensitivity: 'base' });
// by: 'size' (count desc, then name) | 'name'
export const sortTeams = (cards, by) => [...cards].sort(by === 'size' ? (a, b) => b.count - a.count || byName(a, b) : byName);

// Names of non-archived teams where personId is a non-removed member; teams they lead first.
export function teamsOfPerson(projects, personId) {
  const rows = projects.filter((p) => !p.archived).flatMap((p) => {
    const m = p.members.find((x) => x.person_id === personId && !x.removed);
    return m ? [{ name: p.name, lead: m.role === 'lead' }] : [];
  });
  return rows.sort((a, b) => b.lead - a.lead).map((r) => r.name);
}

// "A, B, C" — past `cap` names: "A, …, J and 3 more".
export const nameList = (names, cap = 10) =>
  names.length > cap ? `${names.slice(0, cap).join(', ')} and ${names.length - cap} more` : names.join(', ');

// Tooltip placement (viewport coords): centered above the trigger, kept 8px inside the viewport width; below if no room above.
export function tipPos(r, tip, vw, gap = 6, pad = 8) {
  const left = Math.max(pad, Math.min(r.left + r.width / 2 - tip.width / 2, vw - pad - tip.width));
  const below = r.top - gap - tip.height < pad;
  return { left, top: below ? r.bottom + gap : r.top - gap - tip.height, below };
}
