import { useEffect, useState } from 'react';
import { api } from '../api.js';
import { Btn, Muted } from '../ui.jsx';

export default function People({ me }) {
  const [list, setList] = useState([]), [role, setRole] = useState('member'), [link, setLink] = useState(''), [err, setErr] = useState('');
  useEffect(() => { api.members().then(setList, (e) => setErr(e.message)); }, []);
  return (
    <div>
      <ul className="divide-y divide-neutral-200 border-y border-neutral-200 mb-10">
        {list.map((m) => (
          <li key={m.user_id} className="flex justify-between py-2 text-sm">
            <span>{m.name || m.email}</span><span className="text-neutral-500">{m.role}</span>
          </li>
        ))}
      </ul>
      <div className="flex gap-2 items-center">
        {me.role === 'owner' && (
          <select className="border border-neutral-300 px-2 py-1.5 text-sm" value={role} onChange={(e) => setRole(e.target.value)}>
            <option>member</option><option>admin</option>
          </select>
        )}
        <Btn primary onClick={() => api.invite(role).then((r) => setLink(`${location.origin}/#join=${r.token}`), (e) => setErr(e.message))}>Invite</Btn>
      </div>
      {link && <input readOnly value={link} onFocus={(e) => e.target.select()} className="mt-3 w-full border border-neutral-300 px-3 py-1.5 text-sm" />}
      {err && <Muted>{err}</Muted>}
    </div>
  );
}
