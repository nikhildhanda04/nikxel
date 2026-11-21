import { useEffect, useState } from 'react';
import { api } from '../api.js';
import { Btn, Input, Muted, H } from '../ui.jsx';
import { fmtDate } from './Day.jsx';

export const Avatars = ({ members }) => (
  <span className="flex -space-x-1.5">
    {members.slice(0, 4).map((m) => (
      <span key={m.user_id} title={m.name} className="grid size-6 place-items-center rounded-full border border-bg bg-accent text-[0.65rem] font-medium uppercase text-pill-fg">{(m.name || '?')[0]}</span>
    ))}
    {members.length > 4 && <span className="grid size-6 place-items-center rounded-full border border-bg bg-accent text-[0.65rem] text-pill-fg">+{members.length - 4}</span>}
  </span>
);

export default function Projects() {
  const [list, setList] = useState(null), [err, setErr] = useState('');
  const [name, setName] = useState(''), [desc, setDesc] = useState(''), [formErr, setFormErr] = useState('');
  const load = () => api.projects().then(setList, (e) => setErr(e.message));
  useEffect(() => { load(); }, []);
  const create = (e) => {
    e.preventDefault();
    api.createProject(name.trim(), desc.trim() || undefined).then(({ id }) => { location.hash = 'projects/' + encodeURIComponent(id); },
      (x) => setFormErr(x.status === 409 ? 'That name is taken' : x.message));
  };
  return (
    <div>
      <H>Projects</H>
      <form onSubmit={create} className="mb-6 flex flex-wrap items-center gap-2">
        <Input aria-label="Project name" placeholder="New project" maxLength={80} required value={name} onChange={(e) => { setName(e.target.value); setFormErr(''); }} className="basis-40 flex-1" />
        <Input aria-label="Description" placeholder="Description (optional)" maxLength={200} value={desc} onChange={(e) => setDesc(e.target.value)} className="basis-48 flex-[2]" />
        <Btn primary disabled={!name.trim()}>Create</Btn>
        {formErr && <p role="alert" className="basis-full text-sm text-red-500">{formErr}</p>}
      </form>
      {!list ? <Muted>{err || 'Loading…'}</Muted> : !list.length ? <Muted>No projects yet.</Muted> : (
        <ul className="divide-y divide-line rounded-xl border border-line bg-card">
          {list.map((p) => (
            <li key={p.id}>
              <a href={'#projects/' + encodeURIComponent(p.id)} className="flex items-center gap-3 rounded-xl px-4 py-3 transition-colors hover:bg-accent/50">
                <span className="min-w-0 flex-1">
                  <span className="block truncate font-medium">{p.name}</span>
                  {p.description && <span className="block truncate text-sm text-muted">{p.description}</span>}
                  <span className="block text-xs text-muted">{p.last_activity ? 'active ' + fmtDate(p.last_activity, 'short') : 'no activity yet'}</span>
                </span>
                <Avatars members={p.members} />
              </a>
            </li>
          ))}
        </ul>
      )}
    </div>
  );
}
