import { useEffect, useState } from 'react';
import { api, canEditFacts } from '../api.js';
import { Btn, Muted } from '../ui.jsx';

export default function Mine({ me }) {
  const [rows, setRows] = useState(null), [err, setErr] = useState('');
  const load = () => api.mine().then(setRows, (e) => setErr(e.message));
  useEffect(() => { load(); }, []);
  const act = (p) => p.then(load, (e) => setErr(e.message));
  if (!rows) return <Muted>{err || 'Loading'}</Muted>;
  const work = rows.filter((r) => r.kind === 'work');
  const edit = canEditFacts(me.role);
  return (
    <div className="space-y-10">
      {err && <Muted>{err}</Muted>}
      {!work.length && <Muted>No summaries yet.</Muted>}
      {work.map((s) => {
        const pending = s.status === 'pending';
        return (
          <section key={s.id}>
            <div className="flex items-baseline justify-between mb-3">
              <h2 className="font-medium">{s.date}</h2>
              <Muted>{s.status}</Muted>
            </div>
            <ul className="divide-y divide-neutral-200 border-y border-neutral-200">
              {s.items.filter((i) => !i.removed).map((i) => (
                <li key={i.id} className="flex items-center gap-3 py-2 text-sm">
                  {edit && pending ? <Editable s={s} i={i} act={act} /> : (
                    <><span className="flex-1">{i.what}</span><span className="text-neutral-500">{i.minutes} min</span></>
                  )}
                  {pending && <button className="text-neutral-500 underline" onClick={() => act(api.redact(s.id, i.id))}>Remove</button>}
                </li>
              ))}
            </ul>
            {pending && <Btn primary className="mt-3" onClick={() => act(api.release(s.id))}>Release to admin</Btn>}
          </section>
        );
      })}
    </div>
  );
}

function Editable({ s, i, act }) {
  const save = (patch) => act(api.editItem(s.id, i.id, patch));
  return (
    <>
      <input className="flex-1 border-b border-neutral-300 bg-transparent" defaultValue={i.what}
        onBlur={(e) => e.target.value.trim() && e.target.value !== i.what && save({ what: e.target.value })} />
      <input className="w-16 border-b border-neutral-300 bg-transparent text-right" type="number" min="0" defaultValue={i.minutes}
        onBlur={(e) => e.target.value !== '' && +e.target.value !== i.minutes && save({ minutes: +e.target.value })} />
      <span className="text-neutral-500">min</span>
    </>
  );
}
