import { useEffect, useState } from 'react';
import { api } from '../api.js';
import { Btn, Muted, H } from '../ui.jsx';

export default function People({ me }) {
  const [list, setList] = useState([]), [role, setRole] = useState('member'), [link, setLink] = useState(''), [err, setErr] = useState('');
  const load = () => api.members().then(setList, (e) => setErr(e.message));
  useEffect(() => { load(); }, []);
  const flip = (m) => api.setRole(m.user_id, m.role === 'admin' ? 'member' : 'admin').then(load, (e) => setErr(e.message));
  return (
    <div>
      <H>People</H>
      <ul className="mb-10 divide-y divide-line rounded-2xl border border-line bg-surface">
        {list.map((m) => (
          <li key={m.user_id} className="flex flex-wrap items-center gap-x-3 gap-y-1 px-4 py-3 text-sm">
            <span className="min-w-0 flex-1">
              <span className="block truncate font-medium">{m.name || m.email}</span>
              {m.name && <span className="block truncate text-xs text-muted">{m.email}</span>}
            </span>
            <span className={`rounded-full px-2 py-0.5 text-xs ${m.role === 'member' ? 'text-muted' : 'bg-indigo-soft'}`}>{m.role}</span>
            {m.role !== 'owner' && m.user_id !== me.userId && (
              <Btn onClick={() => flip(m)}>{m.role === 'admin' ? 'Make member' : 'Make admin'}</Btn>
            )}
          </li>
        ))}
      </ul>
      <H>Invite</H>
      <div className="flex gap-2 items-center">
        <label className="sr-only" htmlFor="invite-role">Role</label>
        <select id="invite-role" className="rounded-full border border-line bg-surface px-3 py-1.5 text-sm" value={role} onChange={(e) => setRole(e.target.value)}>
          <option>member</option><option>admin</option>
        </select>
        <Btn primary onClick={() => api.invite(role).then((r) => setLink(`${location.origin}/#join=${r.token}`), (e) => setErr(e.message))}>Create invite link</Btn>
      </div>
      {link && <input readOnly aria-label="Invite link" value={link} onFocus={(e) => e.target.select()} className="mt-3 w-full rounded-lg border border-line bg-surface px-3 py-1.5 text-sm" />}
      {err && <Muted className="mt-3">{err}</Muted>}
    </div>
  );
}
