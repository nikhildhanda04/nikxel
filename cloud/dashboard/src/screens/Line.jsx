import { fmtMin } from './Day.jsx';

const W = 100, H = 120;
const short = (d) => new Date(d + 'T00:00').toLocaleDateString('en-GB', { day: 'numeric', month: 'short' });

// Hours per calendar day, one 2px line per series ({id, name, total, points, color, dashed}), shared y-scale.
// The SVG stretches to its box; non-scaling strokes keep lines 2px at any width.
export default function Line({ name, series, range }) {
  const max = Math.max(...series.flatMap((s) => s.points)), n = range.length;
  const tick = [480, 240, 120, 60].find((t) => t <= max * 0.9) || max; // a clean reference line
  const x = (i) => (i / (n - 1)) * W, y = (m) => H - 1 - (m / max) * (H - 8);
  return (
    <div>
      <div className="relative">
        <svg viewBox={`0 0 ${W} ${H}`} preserveAspectRatio="none" role="img" width="100%" height={H} className="block overflow-visible"
          aria-label={`${name}: ` + series.map((s) => `${s.name} ${fmtMin(s.total)}`).join(', ')}>
          <line x1="0" x2={W} y1={y(tick)} y2={y(tick)} stroke="var(--line)" vectorEffect="non-scaling-stroke" />
          <line x1="0" x2={W} y1={H - 0.5} y2={H - 0.5} stroke="var(--line)" vectorEffect="non-scaling-stroke" />
          {[...series].reverse().map((s) => ( // biggest drawn last, on top
            <path key={s.id} d={s.points.map((m, i) => `${i ? 'L' : 'M'}${x(i)} ${y(m)}`).join('')} fill="none" stroke={s.color} strokeWidth="2"
              strokeLinejoin="round" strokeLinecap="round" strokeDasharray={s.dashed ? '4 3' : undefined} vectorEffect="non-scaling-stroke" />
          ))}
          {range.map((d, i) => ( // hover: a full-height column per day
            <rect key={d} x={x(i) - W / (n - 1) / 2} width={W / (n - 1)} y="0" height={H} fill="transparent">
              <title>{`${short(d)}: ` + series.map((s) => `${s.name} ${fmtMin(s.points[i])}`).join(', ')}</title>
            </rect>
          ))}
        </svg>
        <span aria-hidden="true" className="pointer-events-none absolute left-0 -translate-y-full bg-card pr-1 text-[10px] leading-none text-muted tabular-nums" style={{ top: y(tick) - 3 }}>{fmtMin(tick)}</span>
      </div>
      <div className="mt-1.5 flex justify-between text-[11px] text-muted tabular-nums" aria-hidden="true">
        <span>{short(range[0])}</span><span>{short(range[n - 1])}</span>
      </div>
      <ul className="mt-4 space-y-1.5 text-sm">
        {series.map((s) => (
          <li key={s.id} className="flex items-center gap-2">
            <svg width="14" height="8" aria-hidden="true" className="shrink-0"><line x1="1" x2="13" y1="4" y2="4" stroke={s.color} strokeWidth="2" strokeLinecap="round" strokeDasharray={s.dashed ? '3 3' : undefined} /></svg>
            <span className="min-w-0 flex-1 truncate">{s.name}</span>
            <span className="shrink-0 text-muted tabular-nums">{fmtMin(s.total)}</span>
          </li>
        ))}
      </ul>
    </div>
  );
}
