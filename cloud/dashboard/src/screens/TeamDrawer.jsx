import { useEffect, useRef, useState } from 'react';
import { api } from '../api.js';
import { Btn, Icon, Input, Muted, Tag } from '../ui.jsx';

export const selCls = 'h-8 min-w-0 rounded-lg border border-line bg-card px-2 text-sm text-fg';
const STAR = 'M12 3l2.7 5.6 6.1.9-4.4 4.3 1 6.1L12 17l-5.5 2.9 1-6.1-4.4-4.3 6.1-.9z';
const FOCUSABLE = 'button:not([disabled]), input, select, [href], [tabindex]:not([tabindex="-1"])';

// Right-side editor for one team (full-screen sheet below 640px). p: a teamCards row (removed members dropped, leads first).
export default function TeamDrawer({ p, people, err, run, close }) {
  const [name, setName] = useState(null); // name !== null: renaming
  const panel = useRef(null);
  const inTeam = new Set(p.members.map((m) => m.person_id));
  const addable = people.filter((x) => !inTeam.has(x.id));
  const save = (e) => { e.preventDefault(); run(api.patchProject(p.id, { name }).then(() => setName(null))); };

  useEffect(() => {
    panel.current.focus();
    const body = document.body.style.overflow;
    document.body.style.overflow = 'hidden';
    // Window-level so it still works when the focused control unmounts (Remove, Rename) and focus drops to body.
    const onKey = (e) => {
      if (e.key === 'Escape') return close();
      if (e.key !== 'Tab') return;
      const el = panel.current, f = [...el.querySelectorAll(FOCUSABLE)], at = document.activeElement;
      if (!f.length) return;
      const first = f[0], last = f[f.length - 1];
      if (!el.contains(at)) { e.preventDefault(); (e.shiftKey ? last : first).focus(); }
      else if (e.shiftKey && (at === first || at === el)) { e.preventDefault(); last.focus(); }
      else if (!e.shiftKey && at === last) { e.preventDefault(); first.focus(); }
    };
    addEventListener('keydown', onKey);
    return () => {
      removeEventListener('keydown', onKey);
      document.body.style.overflow = body;
      document.querySelector(`[data-team="${CSS.escape(String(p.id))}"]`)?.focus(); // hand focus back to the card
    };
  }, [p.id]);
  // Esc while renaming cancels the rename only (React's stopPropagation keeps it from the window listener).
  const cancelRename = () => { setName(null); panel.current.focus(); };

  return (
    <div className="fixed inset-0 z-50">
      <div className="absolute inset-0 bg-black/30" onClick={close} aria-hidden="true" />
      <div ref={panel} role="dialog" aria-modal="true" aria-labelledby="team-drawer-title" tabIndex={-1}
        className="absolute inset-y-0 right-0 flex w-full flex-col overflow-y-auto border-l border-line bg-bg p-5 shadow-2xl outline-none sm:w-[440px]">
        <div className="flex items-start gap-2">
          {name === null ? (
            <h2 id="team-drawer-title" className="min-w-0 flex-1 font-heading text-xl font-semibold tracking-tight break-words">{p.name}</h2>
          ) : (
            <form onSubmit={save} onKeyDown={(e) => { if (e.key === 'Escape') { e.stopPropagation(); cancelRename(); } }} className="flex min-w-0 flex-1 gap-2">
              <h2 id="team-drawer-title" className="sr-only">Rename {p.name}</h2>
              <Input autoFocus aria-label="Project name" value={name} maxLength={200} onChange={(e) => setName(e.target.value)} />
              <Btn primary disabled={!name.trim()}>Save</Btn>
              <Btn type="button" onClick={cancelRename}>Cancel</Btn>
            </form>
          )}
          <button onClick={close} aria-label="Close" className="-mr-1 grid size-8 shrink-0 place-items-center rounded-full text-muted transition-colors hover:bg-accent hover:text-fg">
            <Icon d="M6 6l12 12M18 6L6 18" className="size-4" />
          </button>
        </div>
        {(p.archived || !p.active) && (
          <div className="mt-2 flex gap-1.5">{p.archived && <Tag>archived</Tag>}{!p.active && <Tag>inactive in ERP</Tag>}</div>
        )}
        {p.description && <p className="mt-2 text-sm text-muted">{p.description}</p>}
        {err && <p role="alert" className="mt-3 rounded-lg bg-accent px-3 py-2 text-sm">{err}</p>}

        <h3 className="mt-6 mb-2 text-xs font-medium uppercase tracking-wider text-muted">
          Members <span className="tabular-nums">{p.members.length}</span>
        </h3>
        {!p.members.length ? <Muted>No members.</Muted> : (
          <ul className="divide-y divide-line rounded-xl border border-line bg-card">
            {p.members.map((m) => {
              const lead = m.role === 'lead';
              return (
                <li key={m.person_id} className="flex h-10 items-center gap-1 px-2 text-sm">
                  <button onClick={() => run(api.setMember(p.id, m.person_id, lead ? 'member' : 'lead'))} aria-pressed={lead}
                    aria-label={lead ? `${m.name} is lead; make member` : `Make ${m.name} lead`} title={lead ? 'Lead' : 'Make lead'}
                    className={`grid size-7 shrink-0 place-items-center rounded-md transition-colors ${lead ? 'text-fg' : 'text-muted/60 hover:text-fg'}`}>
                    <svg viewBox="0 0 24 24" className="size-3.5" fill={lead ? 'currentColor' : 'none'} stroke="currentColor" strokeWidth="2" strokeLinejoin="round" aria-hidden="true"><path d={STAR} /></svg>
                  </button>
                  <span className={`min-w-0 flex-1 truncate ${lead ? 'font-medium' : ''}`}>{m.name}</span>
                  {lead && <span className="text-xs text-muted">lead</span>}
                  <button onClick={() => run(api.removeMember(p.id, m.person_id))} aria-label={`Remove ${m.name}`} title="Remove"
                    className="grid size-7 shrink-0 place-items-center rounded-md text-muted transition-colors hover:text-fg">
                    <Icon d="M6 6l12 12M18 6L6 18" className="size-3" />
                  </button>
                </li>
              );
            })}
          </ul>
        )}
        {addable.length > 0 && (
          <select aria-label={`Add a person to ${p.name}`} className={`${selCls} mt-3 w-full`} value="" onChange={(e) => run(api.setMember(p.id, e.target.value, 'member'))}>
            <option value="" disabled>Add person…</option>
            {addable.map((x) => <option key={x.id} value={x.id}>{x.name}</option>)}
          </select>
        )}

        <div className="mt-auto flex gap-2 pt-8">
          {name === null && <Btn onClick={() => setName(p.name)}>Rename</Btn>}
          <Btn onClick={() => run(api.patchProject(p.id, { archived: !p.archived }))}>{p.archived ? 'Unarchive' : 'Archive'}</Btn>
        </div>
      </div>
    </div>
  );
}
