import { useState } from 'react';
import { api } from '../api.js';
import { filterPeople, teamsOfPerson } from '../orgView.js';
import { Btn, Chips, H, Input, Muted, Tag, Tip } from '../ui.jsx';
import { selCls } from './TeamDrawer.jsx';

const PILLS = 2; // team pills per row before "+n"
const th = 'px-4 py-2 text-left text-xs font-medium uppercase tracking-wider text-muted';

// Name | Email | Teams | Status. Every row shown. Below 1024px (the page only breaks out of 640px at lg) a row is two lines: name, then teams + status.
export default function PeopleTable({ org, members, membersErr, err, run }) {
  const [q, setQ] = useState(''), [which, setWhich] = useState('all'), [copied, setCopied] = useState('');
  const rows = filterPeople(org.people, q, which);
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
      {!rows.length ? <Muted>No one matches.</Muted> : (
        <div className="rounded-xl border border-line bg-card">
          <table className="w-full table-fixed text-sm max-lg:block">
            <thead className="max-lg:sr-only">
              <tr className="border-b border-line">
                <th className={`${th} w-[26%]`}>Name</th><th className={`${th} w-[20%]`}>Email</th><th className={th}>Teams</th><th className={`${th} w-56 text-right`}>Status</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-line max-lg:block">
              {rows.map((p) => {
                const teams = teamsOfPerson(org.projects, p.id), more = teams.length - PILLS;
                const Box = more > 0 ? 'button' : 'span'; // +n hides teams: a real button so keyboard/screen-reader users reach the full list (aria-describedby)
                const manager = p.manager_erp_id != null && managerOf.get(p.manager_erp_id);
                const sub = [p.title, manager && `reports to ${manager}`].filter(Boolean).join(' · ');
                return (
                  <tr key={p.id} className="align-top max-lg:grid max-lg:grid-cols-[minmax(0,1fr)_auto] max-lg:gap-x-3 max-lg:gap-y-2 max-lg:px-4 max-lg:py-3">
                    <td className="min-w-0 lg:px-4 lg:py-2.5 max-lg:col-span-2">
                      <span title={p.name} className="block truncate font-medium">{p.name}</span>
                      <span className="block truncate text-xs text-muted">
                        {sub || (p.email ? '' : '—')}<span className="lg:hidden">{sub && p.email ? ' · ' : ''}{p.email}</span>
                      </span>
                      {p.note && <p className="mt-1 text-xs text-muted line-clamp-2">{p.note}</p>}
                      {err['p' + p.id] && <Muted className="mt-1">{err['p' + p.id]}</Muted>}
                    </td>
                    <td className="truncate px-4 py-2.5 text-muted max-lg:hidden" title={p.email || undefined}>{p.email || '—'}</td>
                    <td className="min-w-0 lg:px-4 lg:py-2.5">
                      {!teams.length ? <span className="text-muted">—</span> : (
                        <Tip tip={teams.join(', ')} tap>
                          <Box type={more > 0 ? 'button' : undefined} className="flex min-w-0 flex-wrap items-center gap-1 rounded-md text-left outline-offset-2">
                            {teams.slice(0, PILLS).map((t) => <Tag key={t} className="min-w-0 max-w-36">{t}</Tag>)}
                            {more > 0 && <span className="text-xs text-muted tabular-nums">+{more}</span>}
                          </Box>
                        </Tip>
                      )}
                    </td>
                    <td className="lg:px-4 lg:py-2.5">
                      <div className="flex flex-wrap items-center justify-end gap-2">
                        {p.joined ? <Tip tip="Linked to a Nikxel account" tap><span><Tag dot="var(--fg)">joined</Tag></span></Tip> : <>
                          {free.length > 0 && (
                            <select aria-label={`Link ${p.name} to a user`} className={`${selCls} max-w-36`} value="" onChange={(e) => run('p' + p.id, api.linkPerson(p.id, e.target.value))}>
                              <option value="" disabled>Link to user…</option>
                              {free.map((m) => <option key={m.user_id} value={m.user_id}>{m.name || m.email}</option>)}
                            </select>
                          )}
                          <Btn onClick={() => invite(p)}>{copied === p.id ? 'Link copied' : 'Invite'}</Btn>
                        </>}
                      </div>
                    </td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </div>
      )}
    </section>
  );
}
