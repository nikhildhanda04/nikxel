import { TYPE_ORDER } from '../api.js';
import { byPersonDay, byProject, typeTotals, dayRange, NO_PROJECT } from '../stats.js';
import { fmtMin, typeMeta } from './Day.jsx';

const DAYS = 14;
const short = (d) => new Date(d + 'T00:00').toLocaleDateString('en-GB', { day: 'numeric', month: 'short' });
const hrs = (m) => fmtMin(Math.round(m));

// Admin overview over the last 14 calendar days ending at the newest sent day.
export default function Charts({ rows }) {
  const newest = rows.reduce((d, r) => (r.date > d ? r.date : d), '');
  const range = newest ? dayRange(newest, DAYS) : [];
  const recent = rows.filter((r) => r.date >= range[0]);
  const projects = byProject(recent).filter((p) => p.minutes > 0);
  return (
    <div className="mb-10 grid items-start gap-4 sm:grid-cols-2">
      <Card title="Hours per person" sub={`Last ${DAYS} days, by type`} className="sm:col-span-2">
        <PersonDays rows={rows} range={range} />
      </Card>
      <Card title="Time by project" sub={`Last ${DAYS} days`}>
        <HBars name="Time by project" bars={projects.map((p) => ({ label: p.project, minutes: p.minutes, color: p.project === NO_PROJECT ? 'var(--t-other)' : 'var(--fg)' }))} />
      </Card>
      <Card title="Time by type" sub={`Last ${DAYS} days`}>
        <HBars name="Time by type" bars={typeTotals(recent).map((t) => ({ label: typeMeta(t.type).label, minutes: t.minutes, color: typeMeta(t.type).color }))} />
      </Card>
    </div>
  );
}

const Card = ({ title, sub, className = '', children }) => (
  <section className={`min-w-0 rounded-xl border border-line bg-card p-4 ${className}`}>
    <h3 className="font-heading text-base font-semibold tracking-tight">{title}</h3>
    <p className="mb-4 text-xs text-muted">{sub}</p>
    {children}
  </section>
);
const Empty = () => <p className="py-6 text-center text-sm text-muted">No days sent yet</p>;

// Small multiples: one strip per person, a stacked column per calendar day, shared y-scale.
function PersonDays({ rows, range }) {
  const data = byPersonDay(rows, DAYS);
  if (!data.length) return <Empty />;
  const people = [...new Map(data.map((d) => [d.user_id, d.name]))].sort((a, b) => a[1].localeCompare(b[1]));
  const cell = new Map(data.map((d) => [d.user_id + '|' + d.date, d]));
  const totals = {};
  for (const d of data) for (const [t, m] of Object.entries(d.byType)) totals[t] = (totals[t] || 0) + m;
  const types = TYPE_ORDER.filter((t) => totals[t]).sort((a, b) => totals[b] - totals[a]);
  const max = Math.max(...data.map((d) => d.minutes));
  const tick = [480, 240, 120, 60].find((t) => t <= max * 0.9) || max; // a clean reference line
  const H = 52, slot = 100 / range.length;
  const y = (m) => (m / max) * (H - 4);

  return (
    <div>
      <Legend items={types.map((t) => [typeMeta(t).color, typeMeta(t).label])} />
      <div className="mt-3 space-y-4">
        {people.map(([id, name]) => {
          const days = range.map((d) => cell.get(id + '|' + d));
          const sum = days.reduce((n, d) => n + (d?.minutes || 0), 0);
          const label = `${name}: ${hrs(sum)} over ${DAYS} days. ` + days.filter(Boolean).map((d) => `${short(d.date)} ${hrs(d.minutes)}`).join(', ');
          return (
            <div key={id}>
              <div className="mb-1 flex items-baseline justify-between gap-2 text-sm">
                <span className="truncate font-medium">{name}</span>
                <span className="shrink-0 text-muted tabular-nums">{hrs(sum)}</span>
              </div>
              <svg role="img" aria-label={label} width="100%" height={H} className="block overflow-visible">
                <line x1="0" x2="100%" y1={H - y(tick)} y2={H - y(tick)} stroke="var(--line)" />
                <line x1="0" x2="100%" y1={H - 0.5} y2={H - 0.5} stroke="var(--line)" />
                {days.map((d, i) => {
                  if (!d) return null;
                  let base = H;
                  const segs = types.filter((t) => d.byType[t]).map((t) => {
                    const h = y(d.byType[t]), top = base - h;
                    base = top;
                    return <rect key={t} x={`${(i + 0.22) * slot}%`} width={`${slot * 0.56}%`} y={top} height={Math.max(1, h - 2)} rx="1.5" fill={typeMeta(t).color} />;
                  });
                  return (
                    <g key={i}>
                      <title>{`${name}, ${short(d.date)}: ${hrs(d.minutes)} — ` + types.filter((t) => d.byType[t]).map((t) => `${hrs(d.byType[t])} ${typeMeta(t).label.toLowerCase()}`).join(', ')}</title>
                      <rect x={`${i * slot}%`} width={`${slot}%`} y="0" height={H} fill="transparent" />
                      {segs}
                    </g>
                  );
                })}
                <text x="0" y={H - y(tick) - 3} fontSize="10" fill="var(--muted)" stroke="var(--card)" strokeWidth="3" paintOrder="stroke" aria-hidden="true">{hrs(tick)}</text>
              </svg>
            </div>
          );
        })}
      </div>
      <div className="mt-1.5 flex justify-between text-[11px] text-muted tabular-nums" aria-hidden="true">
        <span>{short(range[0])}</span><span>{short(range[range.length - 1])}</span>
      </div>
    </div>
  );
}

const Legend = ({ items }) => (
  <ul className="flex flex-wrap gap-x-3 gap-y-1 text-xs text-muted" aria-hidden="true">
    {items.map(([c, l]) => <li key={l} className="flex items-center gap-1.5"><span className="size-2 rounded-sm" style={{ background: c }} />{l}</li>)}
  </ul>
);

// Labelled horizontal bars: name and value on a line, a thin bar under it.
function HBars({ name, bars }) {
  if (!bars.length) return <Empty />;
  const max = Math.max(...bars.map((b) => b.minutes)), ROW = 34;
  return (
    <svg role="img" aria-label={`${name}: ` + bars.map((b) => `${b.label} ${hrs(b.minutes)}`).join(', ')} width="100%" height={bars.length * ROW} className="block">
      {bars.map((b, i) => (
        <g key={b.label} transform={`translate(0 ${i * ROW})`}>
          <title>{`${b.label}: ${hrs(b.minutes)}`}</title>
          <text x="0" y="12" fontSize="13" fill="var(--fg)">{b.label.length > 34 ? b.label.slice(0, 33) + '…' : b.label}</text>
          <text x="100%" y="12" fontSize="12" fill="var(--muted)" textAnchor="end" style={{ fontVariantNumeric: 'tabular-nums' }}>{hrs(b.minutes)}</text>
          <rect x="0" y="19" width="100%" height="8" rx="4" fill="var(--accent)" />
          <rect x="0" y="19" width={`${Math.max(1, (b.minutes / max) * 100)}%`} height="8" rx="4" fill={b.color} opacity={b.color === 'var(--fg)' ? 0.8 : 1} />
        </g>
      ))}
    </svg>
  );
}
