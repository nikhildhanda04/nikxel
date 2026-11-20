import { useEffect, useState } from 'react';
import { api } from '../api.js';
import { Muted } from '../ui.jsx';

export default function Admin() {
  const [rows, setRows] = useState(null), [names, setNames] = useState({}), [err, setErr] = useState('');
  useEffect(() => {
    api.rollup().then(setRows, (e) => setErr(e.message));
    api.members().then((m) => setNames(Object.fromEntries(m.map((x) => [x.user_id, x.name || x.email]))), () => {});
  }, []);
  if (!rows) return <Muted>{err || 'Loading'}</Muted>;
  const dates = [...new Set(rows.map((r) => r.date))].sort().reverse();
  return (
    <div className="space-y-10">
      {!rows.length && <Muted>Nothing released yet.</Muted>}
      {dates.map((d) => (
        <section key={d}>
          <h2 className="font-medium mb-3">{d}</h2>
          {rows.filter((r) => r.date === d).map((r) => (
            <div key={r.user_id} className="mb-4">
              <p className="text-sm text-neutral-500 mb-1">{names[r.user_id] || r.user_id}</p>
              <ul className="divide-y divide-neutral-200 border-y border-neutral-200">
                {r.items.map((i) => <li key={i.id} className="flex justify-between py-2 text-sm"><span>{i.what}</span><span className="text-neutral-500">{i.minutes} min</span></li>)}
              </ul>
            </div>
          ))}
        </section>
      ))}
    </div>
  );
}
