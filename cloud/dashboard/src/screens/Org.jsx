import { useEffect, useRef, useState } from 'react';
import { api } from '../api.js';
import { orgStats, sortTeams, teamCards, teamSummary } from '../orgView.js';
import { Chips, H, Input, Muted, chipCls } from '../ui.jsx';
import OrgSummary from './OrgSummary.jsx';
import PeopleTable from './PeopleTable.jsx';
import TeamDrawer from './TeamDrawer.jsx';
import TeamGrid from './TeamGrid.jsx';

// route: 'org' (Teams) | 'org/people' | 'org/team/<id>' (Teams with that team's drawer open)
export default function Org({ route = 'org' }) {
  const [org, setOrg] = useState(null), [members, setMembers] = useState([]), [membersErr, setMembersErr] = useState(''), [err, setErr] = useState({});
  const [f, setF] = useState({ q: '', which: 'active', noLead: false, sort: 'size' }); // Teams toolbar; survives drawer open/close
  const closing = useRef(false); // close already in flight (double click / Esc+click)
  const fromGrid = useRef(false); // drawer opened from the grid this session: close = Back (no extra history entry); deep link: replace
  const load = () => api.org().then(setOrg, (e) => setErr((x) => ({ ...x, load: e.message })));
  useEffect(() => { load(); api.members().then(setMembers, (e) => setMembersErr(e.message)); }, []);
  // Every mutation: run it, then refetch the org; errors show next to the thing that failed (keyed).
  const run = (key, p) => p.then(() => { setErr((x) => ({ ...x, [key]: '' })); return load(); }, (e) => setErr((x) => ({ ...x, [key]: e.message })));

  if (!org) return <Muted>{err.load || 'Loading…'}</Muted>;
  if (!org.people.length && !org.projects.length) return (
    <div><H>Org</H><Muted>Nothing yet — in Nikxel, choose Build org from ERP…</Muted></div>
  );
  const [, sub, id] = route.split('/');
  const tab = sub === 'people' ? 'people' : 'teams';
  const open = sub === 'team' ? teamCards(org.projects, 'all').find((p) => encodeURIComponent(p.id) === id) : null; // any status; unknown id: just the grid
  if (!open) { fromGrid.current = false; closing.current = false; } // flag only lives while a grid-opened drawer is up
  const closeDrawer = () => { if (closing.current) return; closing.current = true; if (fromGrid.current) history.back(); else location.replace('#org'); };
  const noLead = () => { setF((x) => ({ ...x, which: 'active', noLead: true })); location.hash = 'org'; };

  return (
    <div className="lg:-mx-[160px] xl:-mx-[280px]">
      <OrgSummary s={orgStats(org)} onNoLead={noLead} />
      <nav aria-label="Org" className="mb-5 flex gap-5 border-b border-line text-sm">
        {[['org', 'Teams', 'teams'], ['org/people', 'People', 'people']].map(([h, l, k]) => (
          <a key={k} href={'#' + h} aria-current={tab === k ? 'page' : undefined}
            className="-mb-px border-b-2 border-transparent pb-2 text-muted transition-colors hover:text-fg aria-[current=page]:border-fg aria-[current=page]:font-medium aria-[current=page]:text-fg">{l}</a>
        ))}
      </nav>
      {tab === 'people'
        ? <PeopleTable org={org} members={members} membersErr={membersErr} err={err} run={run} />
        : <Teams org={org} f={f} setF={setF} fromGrid={fromGrid} />}
      {tab === 'teams' && open && (
        <TeamDrawer key={open.id} p={open} people={org.people} err={err['t' + open.id]} run={(x) => run('t' + open.id, x)} close={() => { setErr((x) => ({ ...x, ['t' + open.id]: '' })); closeDrawer(); }} />
      )}
    </div>
  );
}

function Teams({ org, f, setF, fromGrid }) {
  const set = (k) => (v) => setF((x) => ({ ...x, [k]: v }));
  const s = f.q.trim().toLowerCase();
  const cards = sortTeams(teamCards(org.projects, f.which, { noLead: f.noLead }).filter((p) => !s || p.name.toLowerCase().includes(s)).map(teamSummary), f.sort);
  return (
    <section>
      <div className="mb-4 flex flex-wrap items-center gap-2">
        <Input type="search" placeholder="Search teams" aria-label="Search teams" value={f.q} onChange={(e) => set('q')(e.target.value)} className="sm:max-w-56" />
        <Chips label="Status" value={f.which} set={set('which')} opts={[['active', 'Active'], ['inactive', 'Inactive'], ['archived', 'Archived'], ['all', 'All']]} />
        <button className={chipCls(f.noLead)} aria-pressed={f.noLead} onClick={() => set('noLead')(!f.noLead)}>No lead</button>
        <span className="flex items-center gap-2 sm:ml-auto">
          <span className="text-xs text-muted">Sort</span>
          <Chips label="Sort" value={f.sort} set={set('sort')} opts={[['size', 'Size'], ['name', 'Name']]} />
        </span>
      </div>
      {!cards.length
        ? <Muted>{s ? 'No teams match.' : `No ${f.which === 'all' ? '' : f.which + ' '}teams${f.noLead ? ' without a lead' : ''}.`}</Muted>
        : <TeamGrid cards={cards} open={(id) => { fromGrid.current = true; location.hash = 'org/team/' + encodeURIComponent(id); }} />}
    </section>
  );
}
