import { useState } from 'react';
import { api } from '../api.js';
import { Btn, Muted, H } from '../ui.jsx';
import { assignableRoles, roleLabel } from '../roles.js';

export default function Invite({ me }) {
  const roles = assignableRoles(me.role), [role, setRole] = useState('member'), [link, setLink] = useState(''), [err, setErr] = useState(''), [copied, setCopied] = useState(false);
  const make = () => api.invite(role).then((r) => { setErr(''); setCopied(false); setLink(`${location.origin}/#join=${r.token}`); }, (e) => setErr(e.message));
  const copy = () => navigator.clipboard.writeText(link).then(() => setCopied(true), () => {});
  return (
    <div className="max-w-md">
      <H>Invite</H>
      <div className="flex flex-wrap items-center gap-2">
        {roles.length > 1 && <>
          <label className="sr-only" htmlFor="invite-role">Role</label>
          <select id="invite-role" className="h-8 rounded-lg border border-line bg-card px-2 text-sm" value={role} onChange={(e) => setRole(e.target.value)}>
            {roles.map((r) => <option key={r} value={r}>{roleLabel(r)}</option>)}
          </select>
        </>}
        <Btn primary onClick={make}>Create link</Btn>
      </div>
      {link && (
        <div className="mt-3 flex gap-2">
          <input readOnly aria-label="Invite link" value={link} onFocus={(e) => e.target.select()} className="h-8 w-full min-w-0 rounded-lg border border-line bg-card px-3 text-sm" />
          <Btn onClick={copy}>{copied ? 'Copied' : 'Copy'}</Btn>
        </div>
      )}
      {err && <Muted className="mt-3">{err}</Muted>}
      <Muted className="mt-4">They sign in with Google, install Nikxel, then connect it.</Muted>
    </div>
  );
}
