import { useEffect, useState } from 'react';
import { api } from '../api.js';
import { byProject, parseTask } from '../stats.js';
import { H, Icon, Muted, Tag } from '../ui.jsx';
import { Item, fmtMin, fmtDate } from './Day.jsx';

const plural = (n, w) => `${n} ${w}${n === 1 ? '' : 's'}`;
const href = (p) => '#projects/' + encodeURIComponent(p);

export default function Projects({ name }) {
  const [rows, setRows] = useState(null), [err, setErr] = useState('');
  useEffect(() => { api.rollup().then(setRows, (e) => setErr(e.message)); }, []);
  if (!rows) return <Muted>{err || 'Loading…'}</Muted>;
  const projects = byProject(rows);
  if (name === undefined) return <List projects={projects} />;
  const p = projects.find((x) => x.project === name);
  return p ? <Detail p={p} /> : <div><Back /><Muted>No project called “{name}”.</Muted></div>;
}

function List({ projects }) {
  if (!projects.length) return <Muted>No days sent yet. Projects show up here once people send their days.</Muted>;
  return (
    <div className="space-y-4">
      {projects.map((p) => (
        <a key={p.project} href={href(p.project)} className="rise block rounded-xl border border-line bg-card p-4 transition-colors hover:border-fg/25">
          <div className="flex items-baseline gap-3">
            <h3 className="min-w-0 flex-1 truncate font-heading text-xl font-semibold tracking-tight">{p.project}</h3>
            <span className="shrink-0 text-sm text-muted tabular-nums">{fmtMin(p.minutes)}</span>
          </div>
          <div className="mt-3 flex flex-wrap gap-1.5">
            {p.people.map((x) => <Tag key={x.name}>{x.name}</Tag>)}
          </div>
          <p className="mt-3 flex flex-wrap items-center gap-x-3 gap-y-1 text-xs text-muted">
            <span>{plural(p.meetings, 'meeting')}</span>
            <span>{plural(p.tasks, 'ERP task')}</span>
            <span>Last active {fmtDate(p.lastDate, 'short')}</span>
            <Icon d="M9 6l6 6-6 6" className="ml-auto size-4" />
          </p>
        </a>
      ))}
    </div>
  );
}

const Back = () => (
  <a href="#projects" className="mb-6 inline-flex items-center gap-1 text-sm text-muted transition-colors hover:text-fg">
    <Icon d="M15 6l-6 6 6 6" className="size-4" />Projects
  </a>
);

const Section = ({ title, count, children }) => (
  <section className="mt-8">
    <h3 className="mb-2 flex items-baseline gap-2 font-heading text-base font-semibold tracking-tight">
      {title}{count !== undefined && <span className="text-sm font-normal text-muted tabular-nums">{count}</span>}
    </h3>
    {children}
  </section>
);

function Detail({ p }) {
  const counts = {};
  for (const i of p.items) counts[i.name] = (counts[i.name] || 0) + 1;
  // A task shows up again in every day it was touched; keep its newest mention (items are newest first).
  const tasks = new Map();
  for (const i of p.items) if (i.section === 'erp tasks' && !tasks.has(parseTask(i.what)[0])) tasks.set(parseTask(i.what)[0], i);
  const meetings = p.items.filter((i) => i.section === 'meetings');
  const byDate = new Map();
  for (const i of p.items) if (i.section !== 'erp tasks' && i.section !== 'meetings') byDate.set(i.date, [...(byDate.get(i.date) || []), i]);

  return (
    <div>
      <Back />
      <h2 className="font-heading text-3xl font-semibold tracking-tight text-balance">{p.project}</h2>
      <p className="mt-1 text-sm text-muted">
        <span className="tabular-nums">{fmtMin(p.minutes)}</span> · {p.people.length} {p.people.length === 1 ? 'person' : 'people'} · last active {fmtDate(p.lastDate, 'short')}
      </p>

      <Section title="People">
        <ul className="divide-y divide-line rounded-xl border border-line bg-card px-4">
          {p.people.map((x) => (
            <li key={x.name} className="flex items-baseline gap-3 py-3 text-sm">
              <span className="min-w-0 flex-1 truncate font-medium">{x.name}</span>
              <span className="text-muted">{plural(counts[x.name], 'item')}</span>
              <span className="w-16 text-right tabular-nums">{fmtMin(x.minutes)}</span>
            </li>
          ))}
        </ul>
      </Section>

      <Section title="ERP tasks" count={tasks.size}>
        {!tasks.size ? <Muted>No ERP tasks touched.</Muted> : (
          <ul className="divide-y divide-line rounded-xl border border-line bg-card px-4">
            {[...tasks.values()].map((i) => {
              const [title, stage, due] = parseTask(i.what);
              return (
                <li key={title} className="py-3">
                  <p className="text-[0.95rem] leading-relaxed break-words">{title}</p>
                  <div className="mt-1.5 flex flex-wrap items-center gap-1.5 text-xs text-muted">
                    {stage && <Tag dot={/done|complete/i.test(stage) ? 'var(--t-shipped)' : 'var(--t-other)'}>{stage}</Tag>}
                    {due && <Tag>Due {fmtDate(due, 'short')}</Tag>}
                    <span className="ml-1">{i.name} · {fmtDate(i.date, 'short')}</span>
                  </div>
                </li>
              );
            })}
          </ul>
        )}
      </Section>

      <Section title="Meetings" count={meetings.length}>
        {!meetings.length ? <Muted>No meetings.</Muted> : (
          <ul className="divide-y divide-line rounded-xl border border-line bg-card px-4">
            {meetings.map((i, n) => (
              <li key={n} className="flex items-start gap-3 py-3">
                <div className="min-w-0 flex-1">
                  <p className="text-[0.95rem] leading-relaxed break-words">{i.what}</p>
                  <p className="mt-0.5 text-xs text-muted">{i.name} · {fmtDate(i.date, 'short')}</p>
                </div>
                {i.minutes > 0 && <span className="shrink-0 text-sm text-muted tabular-nums">{fmtMin(i.minutes)}</span>}
              </li>
            ))}
          </ul>
        )}
      </Section>

      <Section title="Work">
        {!byDate.size && <Muted>No work items.</Muted>}
        <div className="space-y-4">
          {[...byDate].sort((a, b) => b[0].localeCompare(a[0])).map(([d, items], n) => {
            const total = items.reduce((m, i) => m + (i.minutes > 0 ? i.minutes : 0), 0);
            return (
              <details key={d} open={n === 0} className="rise rounded-xl border border-line bg-card">
                <summary className="flex items-center gap-2 rounded-xl p-4 text-sm text-muted">
                  <Icon d="M9 6l6 6-6 6" className="chev size-4 transition-transform" />
                  <span className="font-medium text-fg">{fmtDate(d)}</span>
                  <span className="ml-auto tabular-nums">{plural(items.length, 'item')}{total > 0 && ` · ${fmtMin(total)}`}</span>
                </summary>
                <ul className="divide-y divide-line border-t border-line px-4">
                  {items.map((i, k) => <Item key={`${i.id}-${k}`} i={i} who={i.name} />)}
                </ul>
              </details>
            );
          })}
        </div>
      </Section>
    </div>
  );
}
