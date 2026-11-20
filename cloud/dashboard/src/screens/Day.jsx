import { typeMeta, TYPE_ORDER } from '../api.js';
import { Icon } from '../ui.jsx';

export { typeMeta };

const SECTIONS = ['what you worked on', 'meetings', 'whatsapp', 'slack', 'open tasks', 'browsing & reading', 'other'];
const SECTION_LABEL = { whatsapp: 'WhatsApp' };
const STATUS = { open: 'bg-lamp-soft', done: 'bg-sage', unclear: 'bg-rose' };

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
    <details open={open} className="rise group rounded-2xl border border-line bg-surface shadow-[0_1px_0_var(--line)]">
      <summary className="block p-5 sm:p-6 rounded-2xl">
        <div className="flex items-baseline gap-3 text-sm">
          <Icon d="M9 6l6 6-6 6" className="chev size-4 text-faint transition-transform self-center" />
          <span className="font-medium">{fmtDate(day.date)}</span>
          {day.name && <span className="text-muted truncate">{day.name}</span>}
          <span className="ml-auto font-mono text-muted tabular-nums">{total ? fmtMin(total) : ''}</span>
        </div>
        {day.headline && <h3 className="mt-2 font-serif text-2xl sm:text-[1.7rem] leading-tight font-semibold tracking-tight text-balance">{day.headline}</h3>}
        {total > 0 && (
          <>
            <div role="img" aria-label={`Time by type: ${legend}`} className="mt-4 flex h-2.5 gap-0.5 overflow-hidden rounded-full">
              {types.map((t) => <span key={t} style={{ width: `${(byType[t] / total) * 100}%`, background: typeMeta(t).color }} />)}
            </div>
            <ul className="mt-2.5 flex flex-wrap gap-x-3 gap-y-1 text-xs text-muted" aria-hidden="true">
              {types.map((t) => (
                <li key={t} className="flex items-center gap-1.5">
                  <span className="size-2 rounded-full" style={{ background: typeMeta(t).color }} />
                  <span className="font-mono tabular-nums text-ink">{fmtMin(byType[t])}</span> {typeMeta(t).label.toLowerCase()}
                </li>
              ))}
            </ul>
          </>
        )}
      </summary>
      <div className="border-t border-line px-5 sm:px-6 pb-5 sm:pb-6">
        {!items.length && <p className="pt-4 text-sm text-muted">Nothing recorded.</p>}
        {[...groups].filter(([, v]) => v.length).map(([s, v]) => (
          <section key={s} className="pt-5">
            <h4 className="mb-1 text-[0.7rem] font-semibold uppercase tracking-[0.12em] text-faint">{SECTION_LABEL[s] || s[0].toUpperCase() + s.slice(1)}</h4>
            <ul className="divide-y divide-line">{v.map((i, n) => <Item key={`${i.id}-${n}`} i={i} />)}</ul>
          </section>
        ))}
      </div>
    </details>
  );
}

function Item({ i }) {
  const t = typeMeta(i.type), [what, status] = splitStatus(i.what || '');
  return (
    <li className="py-2.5">
      <div className="flex flex-wrap sm:flex-nowrap items-start gap-x-3 gap-y-1">
        <span className="mt-0.5 inline-flex items-center gap-1 rounded-full px-2 py-0.5 text-[0.7rem] font-medium whitespace-nowrap"
          style={{ background: `color-mix(in srgb, ${t.color} 15%, transparent)` }}>
          <span style={{ color: t.color }}><Icon d={t.icon} /></span>{t.label}
        </span>
        <span className="min-w-0 flex-1 basis-full sm:basis-auto order-last sm:order-none text-[0.95rem] leading-snug break-words">
          {what}
          {status && <span className={`ml-2 inline-block rounded-full px-2 py-px align-[1px] text-[0.7rem] font-medium ${STATUS[status]}`}>{status}</span>}
        </span>
        {i.minutes > 0 && <span className="ml-auto font-mono text-sm text-muted tabular-nums whitespace-nowrap">{fmtMin(i.minutes)}</span>}
      </div>
      {i.details?.length > 0 && (
        <details className="mt-1">
          <summary className="inline-flex items-center gap-1 text-xs text-accent">
            <Icon d="M9 6l6 6-6 6" className="chev size-3 transition-transform" />more ({i.details.length})
          </summary>
          <ul className="mt-1.5 space-y-1 border-l-2 border-line pl-3 text-sm text-muted">
            {i.details.map((d, n) => <li key={n}>{d}</li>)}
          </ul>
        </details>
      )}
    </li>
  );
}
