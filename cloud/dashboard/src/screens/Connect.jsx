import { useEffect, useState } from 'react';
import { api } from '../api.js';
import { Muted } from '../ui.jsx';

export default function Connect() {
  const [code, setCode] = useState(null), [err, setErr] = useState('');
  useEffect(() => { api.pairingCode().then((r) => setCode(r.code), (e) => setErr(e.message)); }, []);
  return (
    <div className="rounded-xl border border-line bg-card p-4">
      <p className="text-sm text-muted mb-2">Pairing code</p>
      <p className="font-heading text-5xl font-semibold tracking-widest tabular-nums mb-4">{code ?? '······'}</p>
      <Muted>Enter this in your Nikxel app.</Muted>
      {err && <Muted>{err}</Muted>}
    </div>
  );
}
