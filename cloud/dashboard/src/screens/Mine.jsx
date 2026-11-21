import { useEffect, useState } from 'react';
import { api } from '../api.js';
import { Muted, H } from '../ui.jsx';
import Day from './Day.jsx';

export default function Mine({ userId, title }) {
  const [rows, setRows] = useState(null), [err, setErr] = useState('');
  useEffect(() => { (userId ? api.userSummaries(userId) : api.mine()).then(setRows, (e) => setErr(e.message)); }, [userId]);
  if (!rows) return <Muted>{err || 'Loading…'}</Muted>;
  return (
    <div className="space-y-4">
      {title && <H>{title}</H>}
      {!rows.length && <Muted>{userId ? 'No days sent yet.' : 'No days yet. Press Send on your nightly summary in Nikxel and it shows up here.'}</Muted>}
      {rows.map((d, n) => <Day key={d.id} day={d} open={n === 0} />)}
    </div>
  );
}
