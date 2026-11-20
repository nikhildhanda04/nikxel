import { useEffect, useState } from 'react';
import { api } from '../api.js';
import { Muted } from '../ui.jsx';
import Day from './Day.jsx';

export default function Mine() {
  const [rows, setRows] = useState(null), [err, setErr] = useState('');
  useEffect(() => { api.mine().then(setRows, (e) => setErr(e.message)); }, []);
  if (!rows) return <Muted>{err || 'Loading…'}</Muted>;
  return (
    <div className="space-y-4">
      {!rows.length && <Muted>No days yet. Press Send on your nightly summary in Nikxel and it shows up here.</Muted>}
      {rows.map((d, n) => <Day key={d.id} day={d} open={n === 0} />)}
    </div>
  );
}
