import { useEffect, useState } from 'react';
import { api } from '../api.js';
import { filterPeople, orgStats, sortTeams, teamCards, teamSummary } from '../orgView.js';
import { Btn, H, Input, Muted, Tag, chipCls } from '../ui.jsx';
import OrgSummary from './OrgSummary.jsx';
import TeamDrawer, { selCls } from './TeamDrawer.jsx';
import TeamGrid from './TeamGrid.jsx';

const ROWS = 12; // people rows before "Show all"

function Chips({ label, value, set, opts }) {
  return (
    <div role="group" aria-label={label} className="flex flex-wrap gap-1.5">
      {opts.map(([k, l]) => <button key={k} className={chipCls(value === k)} aria-pressed={value === k} onClick={() => set(k)}>{l}</button>)}
    </div>
  );
}

// route: 'org' (Teams) | 'org/people' | 'org/team/<id>' (Teams with that team's drawer open)
export default function Org({ route = 'org' }) {
  const [org, setOrg] = useState(null), [members, setMembers] = useState([]), [membersErr, setMembersErr] = useState(''), [err, setErr] = useState({});
  const [f, setF] = useState({ q: '', which: 'active', noLead: false, sort: 'size' }); // Teams toolbar; survives drawer open/close
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
        ? <People org={org} members={members} membersErr={membersErr} err={err} run={run} />
        : <Teams org={org} f={f} setF={setF} />}
      {tab === 'teams' && open && (
        <TeamDrawer key={open.id} p={open} people={org.people} err={err['t' + open.id]} run={(x) => run('t' + open.id, x)} close={() => { location.hash = 'org'; }} />
      )}
    </div>
  );
}

function People({ org, members, membersErr, err, run }) {
  const [q, setQ] = useState(''), [which, setWhich] = useState('all'), [copied, setCopied] = useState(''), [all, setAll] = useState(false);
  const matched = filterPeople(org.people, q, which), shown = all ? matched : matched.slice(0, ROWS);
  const managerOf = new Map(org.people.map((p) => [p.erp_id, p.name]));
  const linked = new Set(org.people.map((p) => p.user_id).filter(Boolean));
  const free = members.filter((m) => !linked.has(m.user_id));
  const invite = (p) => run('p' + p.id, api.invite('member').then(async (r) => {
    const link = `${location.origin}/#join=${r.token}`;
    try { await navigator.clipboard.writeText(link); setCopied(p.id); }
    catch { prompt('Copy this invite link', link); } // clipboard blocked (http, permissions): let them copy by hand
  }));
  const joinedN = org.people.filter((p) => p.joined).length;

  return (
    <section className="mb-12">
      <H>People <span className="text-sm font-normal text-muted tabular-nums">{joinedN} of {org.people.length} joined</span></H>
      <div className="mb-4 flex flex-wrap items-center gap-2">
        <Input type="search" placeholder="Search name, email, title" aria-label="Search people" value={q} onChange={(e) => setQ(e.target.value)} className="sm:max-w-64" />
        <Chips label="Joined" value={which} set={setWhich} opts={[['all', 'All'], ['joined', 'Joined'], ['not', 'Not joined']]} />
      </div>
      {membersErr && <Muted className="mb-3">Couldn’t load members, so linking is unavailable: {membersErr}</Muted>}
      {!shown.length ? <Muted>No one matches.</Muted> : (
        <ul className="divide-y divide-line rounded-xl border border-line bg-card">
          {shown.map((p) => (
            <li key={p.id} className="px-4 py-3 text-sm">
              <div className="flex flex-wrap items-center gap-x-3 gap-y-2">
                <span className="min-w-0 flex-1 basis-48">
                  <span className="block truncate font-medium">{p.name}</span>
                  <span className="block truncate text-xs text-muted">
                    {[p.title, p.manager_erp_id != null && managerOf.get(p.manager_erp_id) && `reports to ${managerOf.get(p.manager_erp_id)}`, p.email].filter(Boolean).join(' · ') || '—'}
                  </span>
                </span>
                {p.joined ? <Tag dot="var(--fg)">joined</Tag> : <>
                  {free.length > 0 && (
                    <select aria-label={`Link ${p.name} to a user`} className={selCls} value="" onChange={(e) => run('p' + p.id, api.linkPerson(p.id, e.target.value))}>
                      <option value="" disabled>Link to user…</option>
                      {free.map((m) => <option key={m.user_id} value={m.user_id}>{m.name || m.email}</option>)}
                    </select>
                  )}
                  <Btn onClick={() => invite(p)}>{copied === p.id ? 'Link copied' : 'Invite'}</Btn>
                </>}
              </div>
              {p.note && <p className="mt-1.5 text-xs text-muted line-clamp-2">{p.note}</p>}
              {err['p' + p.id] && <Muted className="mt-1.5">{err['p' + p.id]}</Muted>}
            </li>
          ))}
        </ul>
      )}
      {matched.length > ROWS && (
        <button onClick={() => setAll(!all)} className="mt-3 text-sm text-muted transition-colors hover:text-fg">
          {all ? 'Show fewer' : `Show all ${matched.length}`}
        </button>
      )}
    </section>
  );
}

function Teams({ org, f, setF }) {
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
        : <TeamGrid cards={cards} open={(id) => { location.hash = 'org/team/' + encodeURIComponent(id); }} />}
    </section>
  );
}
