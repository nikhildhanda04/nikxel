import { useEffect, useRef, useState } from 'react';
import { api } from '../api.js';
import { Muted, chipCls as pill } from '../ui.jsx';
import Day, { fmtMin, fmtDate } from './Day.jsx';
import Charts from './Charts.jsx';

const KEY = 'team'; // last picked team id; '' = All people
const remembered = () => { try { return localStorage.getItem(KEY); } catch { return null; } };

// teams: GET /api/teams for the viewer. Owner/admin also get "All people"; a lead picks among the teams they lead.
export default function Team({ teams, admin }) {
  const [team, setTeam] = useState(() => {
    const t = remembered();
    return t !== null && (t === '' ? admin : teams.some((x) => x.id === t)) ? t : admin ? '' : teams[0]?.id;
  });
  const [rows, setRows] = useState(null), [err, setErr] = useState('');
  const [who, setWho] = useState(''), [date, setDate] = useState('');
  const denied = useRef(new Set()); // teams that 403'd this visit (lead rights revoked since the page loaded)
  useEffect(() => {
    let live = true;
    setRows(null); setErr(''); setWho(''); setDate('');
    api.rollup({ team }).then((r) => live && setRows(r), (e) => {
      if (!live) return;
      if (e.status === 403 && team) { // fall back to All (admin) or the next team not yet refused
        denied.current.add(team);
        const next = admin ? '' : teams.find((t) => !denied.current.has(t.id))?.id;
        if (next !== undefined) return pick(next);
      }
      setErr(e.message);
    });
    return () => { live = false; };
  }, [team]);
  const pick = (t) => { setTeam(t); try { localStorage.setItem(KEY, t); } catch {} };

  const picker = <Picker teams={teams} admin={admin} team={team} onPick={pick} />;
  if (!rows) return <div>{picker}<Muted>{err || 'Loading…'}</Muted></div>;

  const people = [...new Map(rows.map((r) => [r.user_id, r.name || r.user_id]))].sort((a, b) => a[1].localeCompare(b[1]));
  const dates = [...new Set(rows.map((r) => r.date))].slice(0, 14); // rows come newest first
  const shown = rows.filter((r) => dates.includes(r.date) && (!who || r.user_id === who) && (!date || r.date === date));
  const newest = shown[0]?.date;
  const mins = shown.reduce((n, r) => n + r.items.reduce((m, i) => m + (i.minutes > 0 ? i.minutes : 0), 0), 0);

  // >=1280px: 280 | 640 | 280 grid, breaking out of the 640px shell column by 280 + 24 each side. Below: one column, charts first.
  return (
    <div>
      {picker}
      <div className="xl:-mx-[304px] xl:grid xl:grid-cols-[280px_640px_280px] xl:items-start xl:gap-6">
        <Charts rows={rows} byMember={!!team} />
        <div className="min-w-0 xl:col-start-2 xl:row-start-1">
          <div className="mb-6 flex flex-wrap items-center gap-2">
            <div role="group" aria-label="Person" className="mr-auto flex flex-wrap gap-1.5">
              <button className={pill(!who)} aria-pressed={!who} onClick={() => setWho('')}>All</button>
              {people.map(([id, n]) => <button key={id} className={pill(who === id)} aria-pressed={who === id} onClick={() => setWho(id)}>{n}</button>)}
            </div>
            <label className="flex items-center gap-2 text-sm text-muted">
              <span className="sr-only">Date</span>
              <select value={date} onChange={(e) => setDate(e.target.value)} className="h-7 rounded-md border border-line bg-card px-2 text-fg">
                <option value="">Last {dates.length} days</option>
                {dates.map((d) => <option key={d} value={d}>{fmtDate(d, 'short')}</option>)}
              </select>
            </label>
          </div>
          {!!shown.length && <Muted className="mb-4">{shown.length} {shown.length === 1 ? 'day' : 'days'} · <span className="tabular-nums">{fmtMin(mins)}</span> tracked</Muted>}
          <div className="space-y-4">
            {!rows.length && <Muted>{team ? 'No one on this team has sent a day yet.' : 'No one has sent a day yet.'}</Muted>}
            {!!rows.length && !shown.length && <Muted>Nothing for this filter.</Muted>}
            {shown.map((r) => <Day key={r.date + r.user_id} day={r} open={r.date === newest} />)}
          </div>
        </div>
      </div>
    </div>
  );
}

// Active ERP projects by default; inactive ones behind a toggle. A search box appears once the list is long.
function Picker({ teams, admin, team, onPick }) {
  const [inactiveOn, setInactiveOn] = useState(false), [q, setQ] = useState('');
  const inactive = teams.filter((t) => t.active === false).length;
  const match = (t) => t.id === team || ((inactiveOn || t.active !== false) && t.name.toLowerCase().includes(q.trim().toLowerCase()));
  const active = teams.filter((t) => t.active !== false && match(t)), off = teams.filter((t) => t.active === false && match(t));
  return (
    <div className="mb-6 flex flex-wrap items-center gap-x-4 gap-y-2">
      <label className="min-w-0">
        <span className="sr-only">Team</span>
        <select value={team} onChange={(e) => onPick(e.target.value)}
          className="h-9 max-w-full rounded-lg border border-line bg-card pl-3 pr-2 font-heading text-lg font-semibold tracking-tight">
          {admin && <option value="">All people</option>}
          {off.length && active.length ? <optgroup label="Active">{active.map(opt)}</optgroup> : active.map(opt)}
          {!!off.length && <optgroup label="Inactive">{off.map(opt)}</optgroup>}
        </select>
      </label>
      {teams.length > 12 && (
        <input type="search" value={q} onChange={(e) => setQ(e.target.value)} placeholder="Find a team" aria-label="Find a team"
          className="h-8 w-40 rounded-lg border border-line bg-card px-3 text-sm placeholder:text-muted" />
      )}
      {!!inactive && (
        <label className="flex items-center gap-2 text-sm text-muted">
          <input type="checkbox" checked={inactiveOn} onChange={(e) => setInactiveOn(e.target.checked)} className="accent-current" />
          Show inactive ({inactive})
        </label>
      )}
    </div>
  );
}
const opt = (t) => <option key={t.id} value={t.id}>{t.name}</option>;
