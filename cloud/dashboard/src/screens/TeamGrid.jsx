import { initials } from '../orgView.js';
import { Tag } from '../ui.jsx';

const AV = 4; // avatars per card before "+k"

// cards: teamSummary rows. Each card is a button; data-team lets the drawer hand focus back on close.
export default function TeamGrid({ cards, open }) {
  return (
    <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-3">
      {cards.map((t) => {
        const lead = t.leads[0];
        return (
          <button key={t.id} data-team={t.id} onClick={() => open(t.id)}
            aria-label={`${t.name} — ${t.count} member${t.count === 1 ? '' : 's'}, ${lead ? `lead ${lead}` : 'no lead'}`}
            className={`flex min-w-0 items-start gap-3 rounded-xl border border-line bg-card px-3 py-2.5 text-left transition-colors hover:border-fg/25 ${t.active && !t.archived ? '' : 'opacity-60'}`}>
            <span className="min-w-0 flex-1">
              <span className="flex min-w-0 items-center gap-1.5">
                <span title={t.name} className="truncate text-sm font-medium">{t.name}</span>
                {t.archived && <Tag className="h-5 shrink-0">archived</Tag>}
                {!t.active && <Tag className="h-5 shrink-0">inactive in ERP</Tag>}
              </span>
              <span className="mt-0.5 block truncate text-xs">
                {lead ? <><span aria-hidden="true">★ </span>{lead}{t.leads.length > 1 && <span className="text-muted"> +{t.leads.length - 1}</span>}</>
                  : <span className="text-muted">— no lead</span>}
              </span>
              <span className="mt-2 flex h-6 items-center gap-1" aria-hidden="true">
                {t.members.slice(0, AV).map((m, i) => (
                  <span key={m.person_id} title={m.name}
                    className={`grid size-6 place-items-center rounded-full text-[10px] font-semibold ${i < t.leads.length ? 'bg-fg text-bg' : 'bg-accent text-pill-fg'}`}>
                    {initials(m.name)}
                  </span>
                ))}
                {t.count > AV && <span className="ml-0.5 text-xs text-muted tabular-nums">+{t.count - AV}</span>}
              </span>
            </span>
            <span className="shrink-0 text-right" aria-hidden="true">
              <span className="block font-heading text-2xl font-semibold leading-none tabular-nums">{t.count}</span>
              <span className="mt-1 block text-[11px] text-muted">{t.count === 1 ? 'member' : 'members'}</span>
            </span>
          </button>
        );
      })}
    </div>
  );
}
