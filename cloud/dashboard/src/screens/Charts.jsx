import { byProject, typeTotals, dayRange, pieSlices, lineSeries, seriesColor, NO_PROJECT, OTHERS } from '../stats.js';
import { fmtMin, typeMeta } from './Day.jsx';
import Pie from './Pie.jsx';
import Line from './Line.jsx';

const DAYS = 14;
const GRAY = 'var(--t-other)';
const sub = `Last ${DAYS} days`;

// Overview of the last 14 calendar days ending at the newest sent day, as two side columns.
// Rendered as a fragment: Team's grid places `left` and `right` around its center column.
// byMember: a team is selected, so the second pie splits by person (colored as in the line chart) rather than by project.
export default function Charts({ rows, byMember }) {
  const newest = rows.reduce((d, r) => (r.date > d ? r.date : d), '');
  const range = newest ? dayRange(newest, DAYS) : [];
  const recent = rows.filter((r) => r.date >= range[0]);
  const projects = byProject(recent).filter((p) => p.minutes > 0);
  // Color follows the person: line-chart order assigns it, the member pie carries it over.
  const series = lineSeries(rows, DAYS).map((s, i) => ({ ...s, color: s.id === OTHERS ? GRAY : seriesColor(i), dashed: s.id === OTHERS }));
  // The "other" type folds into Others: one gray slice, not two.
  const types = pieSlices(typeTotals(recent).map((t) => ({ label: t.type === 'other' ? OTHERS : typeMeta(t.type).label, minutes: t.minutes, color: typeMeta(t.type).color })))
    .map((s) => (s.label === OTHERS ? { ...s, color: GRAY } : s));
  const split = byMember
    ? pieSlices(series.map((s) => ({ id: s.id, label: s.name, minutes: s.total, color: s.color })))
    : pieSlices(projects.map((p) => ({ label: p.project, minutes: p.minutes }))).map(((k) => (s) => ({ ...s, color: s.label === OTHERS || s.label === NO_PROJECT ? GRAY : seriesColor(k++) }))(0)); // gray slices don't use up a color slot
  const col = 'mb-4 grid content-start gap-4 sm:grid-cols-2 xl:sticky xl:top-6 xl:max-h-[calc(100vh-3rem)] xl:overflow-y-auto xl:row-start-1 xl:mb-0 xl:grid-cols-1';

  return (
    <>
      <div className={`${col} xl:col-start-1`}>
        <Card title="Time by type" sub={sub}>{types.length ? <Pie name="Time by type" slices={types} /> : <Empty />}</Card>
        <Card title={byMember ? 'Time by person' : 'Time by project'} sub={sub}>
          {split.length ? <Pie name={byMember ? 'Time by person' : 'Time by project'} slices={split} /> : <Empty />}
        </Card>
      </div>
      <div className={`${col} xl:col-start-3`}>
        <Card title="Hours per day" sub={series.length > 1 ? `${sub}, per person` : sub}>{series.length ? <Line name="Hours per day" series={series} range={range} /> : <Empty />}</Card>
        <Card title="Project hours" sub={sub}>
          <HBars name="Project hours" bars={projects.map((p) => ({ label: p.project, minutes: p.minutes, color: p.project === NO_PROJECT ? GRAY : 'var(--fg)' }))} />
        </Card>
      </div>
    </>
  );
}

const Card = ({ title, sub, children }) => (
  <section className="min-w-0 rounded-xl border border-line bg-card p-4">
    <h3 className="font-heading text-base font-semibold tracking-tight">{title}</h3>
    <p className="mb-4 text-xs text-muted">{sub}</p>
    {children}
  </section>
);
const Empty = () => <p className="py-6 text-center text-sm text-muted">No time tracked yet</p>;

// Labelled horizontal bars: name and value on a line, a thin bar under it.
function HBars({ name, bars }) {
  if (!bars.length) return <Empty />;
  const max = Math.max(...bars.map((b) => b.minutes));
  return (
    <ul role="img" aria-label={`${name}: ` + bars.map((b) => `${b.label} ${fmtMin(b.minutes)}`).join(', ')} className="space-y-3">
      {bars.map((b) => (
        <li key={b.label} title={`${b.label}: ${fmtMin(b.minutes)}`}>
          <div className="flex items-baseline gap-2 text-sm">
            <span className="min-w-0 flex-1 truncate">{b.label}</span>
            <span className="shrink-0 text-xs text-muted tabular-nums">{fmtMin(b.minutes)}</span>
          </div>
          <div className="mt-1.5 h-2 rounded-full bg-accent">
            <div className="h-2 rounded-full" style={{ width: `${Math.max(1, (b.minutes / max) * 100)}%`, background: b.color, opacity: b.color === 'var(--fg)' ? 0.8 : 1 }} />
          </div>
        </li>
      ))}
    </ul>
  );
}
