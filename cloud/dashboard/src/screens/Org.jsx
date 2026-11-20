import { useEffect, useState } from 'react';
import { api } from '../api.js';
import { filterPeople, teamCards } from '../orgView.js';
import { Btn, H, Icon, Input, Muted, Tag, chipCls } from '../ui.jsx';

const selCls = 'h-8 min-w-0 rounded-lg border border-line bg-card px-2 text-sm text-fg';
const STAR = 'M12 3l2.7 5.6 6.1.9-4.4 4.3 1 6.1L12 17l-5.5 2.9 1-6.1-4.4-4.3 6.1-.9z';
const SHOWN = 8; // members per card before "+N more"
const ROWS = 12; // people rows before "Show all"

function Chips({ label, value, set, opts }) {
  return (
    <div role="group" aria-label={label} className="flex flex-wrap gap-1.5">
      {opts.map(([k, l]) => <button key={k} className={chipCls(value === k)} aria-pressed={value === k} onClick={() => set(k)}>{l}</button>)}
    </div>
  );
}

export default function Org() {
  const [org, setOrg] = useState(null), [members, setMembers] = useState([]), [err, setErr] = useState({});
  const load = () => api.org().then(setOrg, (e) => setErr((x) => ({ ...x, load: e.message })));
  useEffect(() => { load(); api.members().then(setMembers, () => {}); }, []);
  // Every mutation: run it, then refetch the org; errors show next to the thing that failed (keyed).
  const run = (key, p) => p.then(() => { setErr((x) => ({ ...x, [key]: '' })); return load(); }, (e) => setErr((x) => ({ ...x, [key]: e.message })));

  if (!org) return <Muted>{err.load || 'Loading…'}</Muted>;
  if (!org.people.length && !org.projects.length) return (
    <div><H>Org</H><Muted>Nothing yet — in Nikxel, choose Build org from ERP…</Muted></div>
  );
  return (
    <div>
      <People org={org} members={members} err={err} run={run} />
      <Teams org={org} err={err} run={run} />
    </div>
  );
}

function People({ org, members, err, run }) {
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

function Teams({ org, err, run }) {
  const [which, setWhich] = useState('active'), [q, setQ] = useState('');
  const s = q.trim().toLowerCase();
  const cards = teamCards(org.projects, which).filter((p) => !s || p.name.toLowerCase().includes(s));
  return (
    <section>
      <H>Teams <span className="text-sm font-normal text-muted tabular-nums">{teamCards(org.projects, 'active').length} active</span></H>
      <div className="mb-4 flex flex-wrap items-center gap-2">
        <Input type="search" placeholder="Search projects" aria-label="Search projects" value={q} onChange={(e) => setQ(e.target.value)} className="sm:max-w-64" />
        <Chips label="Archived" value={which} set={setWhich} opts={[['active', 'Active'], ['all', 'All'], ['archived', 'Archived']]} />
      </div>
      {!cards.length ? <Muted>{which === 'archived' ? 'Nothing archived.' : 'No projects match.'}</Muted> : (
        <div className="space-y-4">{cards.map((p) => <Card key={p.id} p={p} people={org.people} err={err['t' + p.id]} run={(x) => run('t' + p.id, x)} />)}</div>
      )}
    </section>
  );
}

function Card({ p, people, err, run }) {
  const [name, setName] = useState(null), [all, setAll] = useState(false); // name !== null: renaming
  const inTeam = new Set(p.members.map((m) => m.person_id));
  const addable = people.filter((x) => !inTeam.has(x.id));
  const shown = all ? p.members : p.members.slice(0, SHOWN);
  const save = (e) => { e.preventDefault(); run(api.patchProject(p.id, { name }).then(() => setName(null))); };

  return (
    <div className={`rise rounded-xl border border-line bg-card p-4 ${p.archived ? 'opacity-70' : ''}`}>
      {name === null ? (
        <div className="flex flex-wrap items-baseline gap-x-3 gap-y-1">
          <h3 className="min-w-0 flex-1 truncate font-heading text-xl font-semibold tracking-tight">{p.name}</h3>
          {p.archived && <Tag>archived</Tag>}
          {!p.active && <Tag>inactive in ERP</Tag>}
        </div>
      ) : (
        <form onSubmit={save} className="flex gap-2">
          <Input autoFocus aria-label="Project name" value={name} maxLength={200} onChange={(e) => setName(e.target.value)} />
          <Btn primary disabled={!name.trim()}>Save</Btn>
          <Btn type="button" onClick={() => setName(null)}>Cancel</Btn>
        </form>
      )}
      {p.description && <p className="mt-1 text-sm text-muted line-clamp-2">{p.description}</p>}

      <div className="mt-3 flex flex-wrap gap-1.5">
        {!p.members.length && <span className="text-sm text-muted">No members.</span>}
        {shown.map((m) => {
          const lead = m.role === 'lead';
          return (
            <span key={m.person_id} className="inline-flex h-7 max-w-full items-center rounded-md bg-accent text-sm text-pill-fg">
              <button onClick={() => run(api.setMember(p.id, m.person_id, lead ? 'member' : 'lead'))} aria-pressed={lead}
                aria-label={lead ? `${m.name} is lead; make member` : `Make ${m.name} lead`} title={lead ? 'Lead' : 'Make lead'}
                className={`grid h-full place-items-center pl-2 pr-1 transition-colors ${lead ? 'text-fg' : 'text-muted/60 hover:text-fg'}`}>
                <svg viewBox="0 0 24 24" className="size-3.5" fill={lead ? 'currentColor' : 'none'} stroke="currentColor" strokeWidth="2" strokeLinejoin="round" aria-hidden="true"><path d={STAR} /></svg>
              </button>
              <span className={`truncate ${lead ? 'font-medium text-fg' : ''}`}>{m.name}</span>
              <button onClick={() => run(api.removeMember(p.id, m.person_id))} aria-label={`Remove ${m.name}`} title="Remove"
                className="grid h-full place-items-center pl-1 pr-2 text-muted transition-colors hover:text-fg">
                <Icon d="M6 6l12 12M18 6L6 18" className="size-3" />
              </button>
            </span>
          );
        })}
        {p.members.length > SHOWN && (
          <button onClick={() => setAll(!all)} className="h-7 px-1.5 text-sm text-muted transition-colors hover:text-fg">
            {all ? 'Show less' : `+${p.members.length - SHOWN} more`}
          </button>
        )}
      </div>

      <div className="mt-4 flex flex-wrap items-center gap-2">
        {addable.length > 0 && (
          <select aria-label={`Add a person to ${p.name}`} className={`${selCls} mr-auto`} value="" onChange={(e) => run(api.setMember(p.id, e.target.value, 'member'))}>
            <option value="" disabled>Add person…</option>
            {addable.map((x) => <option key={x.id} value={x.id}>{x.name}</option>)}
          </select>
        )}
        <span className="ml-auto flex gap-2">
          {name === null && <Btn onClick={() => setName(p.name)}>Rename</Btn>}
          <Btn onClick={() => run(api.patchProject(p.id, { archived: !p.archived }))}>{p.archived ? 'Unarchive' : 'Archive'}</Btn>
        </span>
      </div>
      {err && <Muted className="mt-3">{err}</Muted>}
    </div>
  );
}
