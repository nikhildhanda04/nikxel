import { useEffect, useState } from 'react';
import { api } from '../api.js';
import { Muted } from '../ui.jsx';

export default function Connect() {
  const [code, setCode] = useState(null), [err, setErr] = useState('');
  useEffect(() => { api.pairingCode().then((r) => setCode(r.code), (e) => setErr(e.message)); }, []);
  return (
    <div>
      <p className="text-5xl tracking-widest tabular-nums mb-4">{code ?? '······'}</p>
      <Muted>Enter this in your Nikxel app.</Muted>
      {err && <Muted>{err}</Muted>}
    </div>
  );
}
