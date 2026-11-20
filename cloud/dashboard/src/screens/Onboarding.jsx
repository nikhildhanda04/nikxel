import { useState } from 'react';
import { api } from '../api.js';
import { Btn, Input, Muted, H } from '../ui.jsx';

export default function Onboarding({ onDone }) {
  const [name, setName] = useState(''), [token, setToken] = useState(''), [err, setErr] = useState('');
  const go = (p) => p.then(onDone, (e) => setErr(e.message));
  return (
    <div className="space-y-10">
      <section>
        <H>Create an org</H>
        <div className="flex gap-2"><Input placeholder="Org name" value={name} onChange={(e) => setName(e.target.value)} />
          <Btn primary disabled={!name.trim()} onClick={() => go(api.createOrg(name))}>Create</Btn></div>
      </section>
      <section>
        <H>Join with a link</H>
        <div className="flex gap-2"><Input placeholder="Paste invite link or token" value={token}
          onChange={(e) => setToken(e.target.value)} />
          <Btn disabled={!token.trim()} onClick={() => go(api.joinOrg(token.trim().split('=').pop()))}>Join</Btn></div>
      </section>
      {err && <Muted>{err}</Muted>}
    </div>
  );
}
