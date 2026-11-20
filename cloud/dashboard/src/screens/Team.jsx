import { useEffect, useState } from 'react';
import { api } from '../api.js';
import { Muted, chipCls as pill } from '../ui.jsx';
import Day, { fmtMin, fmtDate } from './Day.jsx';
import Charts from './Charts.jsx';

export default function Team() {
  const [rows, setRows] = useState(null), [err, setErr] = useState('');
  const [who, setWho] = useState(''), [date, setDate] = useState('');
  useEffect(() => { api.rollup().then(setRows, (e) => setErr(e.message)); }, []);
  if (!rows) return <Muted>{err || 'Loading…'}</Muted>;

  const people = [...new Map(rows.map((r) => [r.user_id, r.name || r.user_id]))].sort((a, b) => a[1].localeCompare(b[1]));
  const dates = [...new Set(rows.map((r) => r.date))].slice(0, 14); // rows come newest first
  const shown = rows.filter((r) => dates.includes(r.date) && (!who || r.user_id === who) && (!date || r.date === date));
  const newest = shown[0]?.date;
  const mins = shown.reduce((n, r) => n + r.items.reduce((m, i) => m + (i.minutes > 0 ? i.minutes : 0), 0), 0);

  return (
    <div>
      <Charts rows={rows} />
      <div className="mb-6 flex flex-wrap items-center gap-2">
        <div role="group" aria-label="Person" className="flex flex-wrap gap-1.5 mr-auto">
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
        {!rows.length && <Muted>No one has sent a day yet.</Muted>}
        {!!rows.length && !shown.length && <Muted>Nothing for this filter.</Muted>}
        {shown.map((r) => <Day key={r.date + r.user_id} day={r} open={r.date === newest} />)}
      </div>
    </div>
  );
}
