import { useEffect, useState } from 'react';
import { api } from '../api.js';
import { Btn, Muted, H } from '../ui.jsx';
import { assignableRoles, roleLabel } from '../roles.js';
import Mine from './Mine.jsx';

export default function People({ me, sub }) {
  const [list, setList] = useState(null), [err, setErr] = useState('');
  const load = () => api.members().then(setList, (e) => setErr(e.message));
  useEffect(() => { load(); }, []);
  const act = (p) => p.then(() => { setErr(''); return load(); }, (e) => setErr(e.message));
  if (!list) return <Muted>{err || 'Loading…'}</Muted>;
  if (sub) {
    const p = list.find((m) => m.user_id === sub);
    return <>
      <a href="#people" className="mb-4 inline-block text-sm text-muted hover:text-fg">← People</a>
      <Mine userId={sub} title={p ? p.name || p.email : 'Summaries'} />
    </>;
  }
  const opts = assignableRoles(me.role);
  return (
    <div>
      <H>People</H>
      <ul className="divide-y divide-line rounded-xl border border-line bg-card">
        {list.map((m) => {
          const fixed = m.role === 'owner' || m.user_id === me.userId;
          return (
            <li key={m.user_id} className="flex flex-wrap items-center gap-x-3 gap-y-2 px-4 py-3 text-sm">
              <span className="min-w-0 flex-1 basis-40">
                <span className="block truncate font-medium">{m.name || m.email}</span>
                {m.name && <span className="block truncate text-xs text-muted">{m.email}</span>}
              </span>
              {fixed || !opts.includes(m.role)
                ? <span className="text-muted">{roleLabel(m.role)}</span>
                : <select aria-label={`Role for ${m.name || m.email}`} className="h-8 rounded-lg border border-line bg-card px-2 text-sm" value={m.role} onChange={(e) => act(api.setRole(m.user_id, e.target.value))}>
                    {opts.map((r) => <option key={r} value={r}>{roleLabel(r)}</option>)}
                  </select>}
              <a href={'#people/' + encodeURIComponent(m.user_id)} className="text-muted underline-offset-2 hover:text-fg hover:underline">Summaries</a>
              {!fixed && <Btn onClick={() => confirm(`Remove ${m.name || m.email}?`) && act(api.removeMember(m.user_id))}>Remove</Btn>}
            </li>
          );
        })}
      </ul>
      {err && <Muted className="mt-3">{err}</Muted>}
    </div>
  );
}
