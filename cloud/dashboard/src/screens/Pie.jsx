import { fmtMin } from './Day.jsx';

const R = 42, C = 2 * Math.PI * R;

// Donut of part-to-whole, <= 6 slices ({label, minutes, pct, color}), total in the hole, a text legend under it.
export default function Pie({ name, slices }) {
  const total = slices.reduce((n, s) => n + s.minutes, 0), gap = slices.length > 1 ? 2 : 0;
  let at = 0;
  return (
    <div>
      <svg viewBox="0 0 100 100" role="img" aria-label={`${name}: ` + slices.map((s) => `${s.label} ${s.pct}% (${fmtMin(s.minutes)})`).join(', ')} className="mx-auto block size-32">
        <g transform="rotate(-90 50 50)">
          {slices.map((s) => {
            const len = (s.minutes / total) * C, off = at;
            at += len;
            return (
              <circle key={s.id ?? s.label} cx="50" cy="50" r={R} fill="none" stroke={s.color} strokeWidth="14"
                strokeDasharray={`${Math.max(0.5, len - gap)} ${C}`} strokeDashoffset={-off}>
                <title>{`${s.label}: ${s.pct}% · ${fmtMin(s.minutes)}`}</title>
              </circle>
            );
          })}
        </g>
        <text x="50" y="50" textAnchor="middle" fontSize="13" fontWeight="600" fill="var(--fg)" style={{ fontVariantNumeric: 'tabular-nums' }}>{fmtMin(total)}</text>
        <text x="50" y="63" textAnchor="middle" fontSize="8.5" fill="var(--muted)">tracked</text>
      </svg>
      <ul className="mt-4 space-y-1.5 text-sm">
        {slices.map((s) => (
          <li key={s.id ?? s.label} className="flex items-center gap-2">
            <span className="size-2.5 shrink-0 rounded-sm" style={{ background: s.color }} />
            <span className="min-w-0 flex-1 truncate">{s.label}</span>
            <span className="w-9 shrink-0 text-right text-muted tabular-nums">{s.pct}%</span>
            <span className="shrink-0 whitespace-nowrap text-right text-muted tabular-nums">{fmtMin(s.minutes)}</span>
          </li>
        ))}
      </ul>
    </div>
  );
}
