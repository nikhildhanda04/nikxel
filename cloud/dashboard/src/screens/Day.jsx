import { typeMeta, TYPE_ORDER } from '../api.js';
import { Icon, Tag } from '../ui.jsx';

export { typeMeta };

const SECTIONS = ['what you worked on', 'meetings', 'whatsapp', 'slack', 'open tasks', 'browsing & reading', 'other'];
const SECTION_LABEL = { whatsapp: 'WhatsApp', 'erp tasks': 'ERP tasks' };
const STATUS = { open: 'var(--t-meeting)', done: 'var(--t-shipped)', unclear: 'var(--t-writing)' };

export const fmtMin = (m) => (m >= 60 ? `${Math.floor(m / 60)}h${m % 60 ? ` ${m % 60}m` : ''}` : `${m}m`);
export const fmtDate = (d, weekday = 'long') => { const t = new Date(d + 'T00:00'); return `${t.toLocaleDateString('en-GB', { weekday })}, ${t.toLocaleDateString('en-GB', { day: 'numeric', month: 'short' })}`; };
const splitStatus = (what) => {
  const m = /\s+[—–-]\s+(open|done|unclear)\.?$/i.exec(what);
  return m ? [what.slice(0, m.index), m[1].toLowerCase()] : [what, null];
};

export default function Day({ day, open = false }) {
  const items = day.items || [];
  const byType = {};
  for (const i of items) if (i.minutes > 0) { const k = TYPE_ORDER.includes(i.type) ? i.type : 'other'; byType[k] = (byType[k] || 0) + i.minutes; }
  const types = TYPE_ORDER.filter((t) => byType[t]).sort((a, b) => byType[b] - byType[a]);
  const total = types.reduce((n, t) => n + byType[t], 0);
  const legend = types.map((t) => `${fmtMin(byType[t])} ${typeMeta(t).label.toLowerCase()}`).join(' · ');

  const groups = new Map(SECTIONS.map((s) => [s, []]));
  for (const i of items) {
    const s = (i.section || 'other').toLowerCase();
    if (!groups.has(s)) groups.set(s, []);
    groups.get(s).push(i);
  }

  return (
    <details open={open} className="rise group rounded-xl border border-line bg-card">
      <summary className="block p-4 rounded-xl">
        <div className="flex items-center gap-2 text-sm text-muted">
          <Icon d="M9 6l6 6-6 6" className="chev size-4 transition-transform" />
          <span className="min-w-0 truncate">
            <span className="text-fg font-medium">{fmtDate(day.date)}</span>
            {day.name && <> · {day.name}</>}
          </span>
          {total > 0 && <span className="ml-auto shrink-0 tabular-nums">{fmtMin(total)}</span>}
        </div>
        {day.headline && <h3 className="mt-2 font-heading text-xl sm:text-2xl leading-tight font-semibold tracking-tight text-balance">{day.headline}</h3>}
        {total > 0 && (
          <>
            <div role="img" aria-label={`Time by type: ${legend}`} className="mt-4 flex h-1.5 gap-0.5 overflow-hidden rounded-full">
              {types.map((t) => <span key={t} style={{ width: `${(byType[t] / total) * 100}%`, background: typeMeta(t).color }} />)}
            </div>
            <ul className="mt-2.5 flex flex-wrap gap-x-3 gap-y-1 text-xs text-muted" aria-hidden="true">
              {types.map((t) => (
                <li key={t} className="flex items-center gap-1.5">
                  <span className="size-1.5 rounded-full" style={{ background: typeMeta(t).color }} />
                  <span className="tabular-nums text-fg">{fmtMin(byType[t])}</span> {typeMeta(t).label.toLowerCase()}
                </li>
              ))}
            </ul>
          </>
        )}
      </summary>
      <div className="border-t border-line px-4 pb-4">
        {!items.length && <p className="pt-4 text-sm text-muted">Nothing recorded.</p>}
        {[...groups].filter(([, v]) => v.length).map(([s, v]) => (
          <section key={s} className="pt-5">
            <h4 className="mb-1 font-heading text-base font-semibold tracking-tight">{SECTION_LABEL[s] || s[0].toUpperCase() + s.slice(1)}</h4>
            <ul className="divide-y divide-line">{v.map((i, n) => <Item key={`${i.id}-${n}`} i={i} />)}</ul>
          </section>
        ))}
      </div>
    </details>
  );
}

// `who` (project view) adds a person tag and drops the project tag, which is the page itself.
export function Item({ i, who }) {
  const t = typeMeta(i.type), [what, status] = splitStatus(i.what || '');
  return (
    <li className="py-3">
      <div className="flex items-start gap-3">
        <p className="min-w-0 flex-1 text-[0.95rem] leading-relaxed break-words">{what}</p>
        {i.minutes > 0 && <span className="shrink-0 text-sm text-muted tabular-nums">{fmtMin(i.minutes)}</span>}
      </div>
      <div className="mt-1.5 flex flex-wrap gap-1.5">
        <Tag dot={t.color}>{t.label}</Tag>
        {who && <Tag>{who}</Tag>}
        {i.project && !who && <Tag className="max-w-full">{i.project}</Tag>}
        {status && <Tag dot={STATUS[status]}>{status}</Tag>}
      </div>
      {i.details?.length > 0 && (
        <details className="mt-1.5">
          <summary className="inline-flex items-center gap-1 text-xs text-muted hover:text-fg">
            <Icon d="M9 6l6 6-6 6" className="chev size-3 transition-transform" />more ({i.details.length})
          </summary>
          <ul className="mt-1.5 space-y-1 border-l border-line pl-3 text-sm text-muted">
            {i.details.map((d, n) => <li key={n}>{d}</li>)}
          </ul>
        </details>
      )}
    </li>
  );
}
