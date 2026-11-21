import { useEffect, useState } from 'react';
import { api } from '../api.js';
import { Btn, Chips, Input, Muted, Tag } from '../ui.jsx';
import { splitFeed, mdBlocks } from '../feed.js';
import { Item, fmtDate } from './Day.jsx';

const Body = ({ md }) => {
  const [all, setAll] = useState(false), blocks = mdBlocks(md), long = blocks.length > 6;
  return (
    <div className="mt-2 text-sm leading-relaxed">
      <div className={long && !all ? 'max-h-36 overflow-hidden' : ''}>
        {blocks.map((b, n) => b.kind === 'h' ? <h5 key={n} className="mt-2 font-heading font-semibold">{b.text}</h5>
          : b.kind === 'li' ? <p key={n} className="flex gap-2 break-words"><span className="text-muted">•</span><span className="min-w-0">{b.text}</span></p>
          : <p key={n} className="break-words">{b.text}</p>)}
      </div>
      {long && <button className="mt-1 text-xs text-muted hover:text-fg" onClick={() => setAll(!all)}>{all ? 'Show less' : 'Show all'}</button>}
    </div>
  );
};

export default function Project({ id }) {
  const [d, setD] = useState(null), [err, setErr] = useState(''), [mode, setMode] = useState('work');
  const [people, setPeople] = useState([]), [edit, setEdit] = useState(null);
  const load = () => api.project(id).then(setD, (e) => setErr(e.status === 404 ? 'Project not found' : e.message));
  useEffect(() => { setD(null); setErr(''); load(); }, [id]);
  const p = d?.project;
  useEffect(() => { if (p?.can_edit) api.members().then(setPeople, () => {}); }, [p?.can_edit]);
  const act = (pr) => pr.then(() => { setErr(''); setEdit(null); return load(); }, (e) => setErr(e.status === 409 ? 'That name is taken' : e.message));
  const back = <a href="#projects" className="mb-4 inline-block text-sm text-muted hover:text-fg">← Projects</a>;
  if (!p) return <>{back}<Muted>{err || 'Loading…'}</Muted></>;

  const days = splitFeed(d.days, mode);
  const free = people.filter((m) => !p.members.some((x) => x.user_id === m.user_id));
  return (
    <div>
      {back}
      {edit ? (
        <form className="mb-4 space-y-2" onSubmit={(e) => { e.preventDefault(); act(api.editProject(id, { name: edit.name.trim(), description: edit.description.trim() })); }}>
          <Input aria-label="Name" maxLength={80} required value={edit.name} onChange={(e) => setEdit({ ...edit, name: e.target.value })} />
          <Input aria-label="Description" maxLength={200} placeholder="Description" value={edit.description} onChange={(e) => setEdit({ ...edit, description: e.target.value })} />
          <div className="flex gap-2"><Btn primary disabled={!edit.name.trim()}>Save</Btn><Btn type="button" onClick={() => setEdit(null)}>Cancel</Btn></div>
        </form>
      ) : (
        <>
          <h2 className="font-heading text-2xl font-semibold tracking-tight break-words">{p.name}{p.archived && <span className="ml-2 align-middle text-sm font-normal text-muted">archived</span>}</h2>
          {p.description && <Muted className="mt-1">{p.description}</Muted>}
        </>
      )}
      {err && <p role="alert" className="mt-2 text-sm text-red-500">{err}</p>}
      <div className="mt-3 flex flex-wrap items-center gap-1.5">
        {p.members.map((m) => (
          <Tag key={m.user_id}>{m.name}{p.can_edit && <button aria-label={`Remove ${m.name}`} className="ml-1.5 text-muted hover:text-fg" onClick={() => act(api.removeProjectMember(id, m.user_id))}>×</button>}</Tag>
        ))}
        {p.can_edit && free.length > 0 && (
          <select aria-label="Add member" value="" className="h-6 rounded-md border border-line bg-card px-1.5 text-xs" onChange={(e) => e.target.value && act(api.addProjectMember(id, e.target.value))}>
            <option value="">+ Add member</option>
            {free.map((m) => <option key={m.user_id} value={m.user_id}>{m.name || m.email}</option>)}
          </select>
        )}
      </div>
      {p.can_edit && !edit && (
        <div className="mt-3 flex gap-2">
          <Btn onClick={() => setEdit({ name: p.name, description: p.description || '' })}>Edit</Btn>
          <Btn onClick={() => act(api.editProject(id, { archived: !p.archived }))}>{p.archived ? 'Unarchive' : 'Archive'}</Btn>
        </div>
      )}
      <div className="mt-6 mb-4"><Chips label="Feed" value={mode} set={setMode} opts={[['work', 'Work'], ['meetings', 'Meetings']]} /></div>
      {!d.days.length ? <Muted>Nothing yet. Work tagged to this project at 10pm and meeting minutes shared from Nikxel show up here.</Muted>
        : !days.length ? <Muted>{mode === 'work' ? 'No work yet.' : 'No meetings yet.'}</Muted>
        : days.map((day) => (
          <section key={day.date} className="mb-4 rounded-xl border border-line bg-card p-4">
            <h3 className="font-heading text-base font-semibold tracking-tight">{fmtDate(day.date)}</h3>
            {day.meetings.map((m) => (
              <article key={m.id} className="mt-3 rounded-lg bg-accent/50 p-3">
                <div className="flex flex-wrap items-baseline gap-x-2"><h4 className="font-medium break-words">{m.title}</h4><span className="text-xs text-muted">shared by {m.name}</span></div>
                <Body md={m.body} />
              </article>
            ))}
            {day.items.length > 0 && <ul className="divide-y divide-line">{day.items.map((i, n) => <Item key={`${i.id}-${n}`} i={i} who={i.name} />)}</ul>}
          </section>
        ))}
    </div>
  );
}
