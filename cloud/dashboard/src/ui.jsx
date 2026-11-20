import { cloneElement, useEffect, useId, useLayoutEffect, useRef, useState } from 'react';
import { createPortal } from 'react-dom';
import { tipPos } from './orgView.js';

// lafda's "Sign in" pill: hairline border, secondary fill, inset top highlight.
export const pillCls = 'inline-flex h-8 items-center gap-1.5 rounded-full border border-fg/15 bg-accent px-3.5 text-sm font-medium shadow-[inset_0_1px_0_0_var(--hi)] transition-colors hover:border-fg/30 disabled:opacity-40';
export const Btn = ({ primary, className = '', ...p }) => (
  <button {...p} className={`${primary ? 'inline-flex h-8 items-center rounded-full bg-fg px-3.5 text-sm font-medium text-bg transition-opacity hover:opacity-85 disabled:opacity-40' : pillCls} ${className}`} />
);
export const Input = (p) => <input {...p} className={`h-8 rounded-lg border border-line bg-card px-3 text-sm w-full min-w-0 placeholder:text-muted ${p.className || ''}`} />;
export const Muted = ({ children, className = '' }) => <p className={`text-sm text-muted ${className}`}>{children}</p>;
export const H = ({ children }) => <h2 className="font-heading text-xl font-semibold tracking-tight mb-4">{children}</h2>;
// Small gray tag, like lafda's topic pills. `dot` adds a colored dot in front.
export const Tag = ({ dot, children, className = '' }) => (
  <span className={`inline-flex h-6 items-center gap-1.5 rounded-md bg-accent px-2 text-xs text-pill-fg whitespace-nowrap ${className}`}>
    {dot && <span className="size-1.5 shrink-0 rounded-full" style={{ background: dot }} />}<span className="truncate">{children}</span>
  </span>
);
export const Icon = ({ d, className = 'size-3.5' }) => (
  <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true" className={`shrink-0 ${className}`}><path d={d} /></svg>
);
// Filter chip: dark when on, like lafda's topic filters.
export const chipCls = (on) => `inline-flex h-7 items-center rounded-md px-2.5 text-sm transition-colors ${on ? 'bg-fg text-bg' : 'bg-accent text-pill-fg hover:text-fg'}`;
export function Chips({ label, value, set, opts }) {
  return (
    <div role="group" aria-label={label} className="flex flex-wrap gap-1.5">
      {opts.map(([k, l]) => <button key={k} className={chipCls(value === k)} aria-pressed={value === k} onClick={() => set(k)}>{l}</button>)}
    </div>
  );
}

// Tooltip around one DOM element (span or button). Shows on mouse hover and keyboard focus (focus-visible);
// hides on Esc, blur, mouse leave, click, scroll or a tap elsewhere. `tap`: a tap on the trigger toggles it (touch, non-interactive triggers).
// `describe`: wire aria-describedby — leave off when the trigger's label already says the same, or it sits inside an aria-hidden/button region.
export function Tip({ tip, children, tap = false, describe = true }) {
  const [open, setOpen] = useState(false), [pos, setPos] = useState(null);
  const id = useId(), ref = useRef(null), box = useRef(null);
  useLayoutEffect(() => {
    if (!open) return setPos(null);
    setPos(tipPos(ref.current.getBoundingClientRect(), box.current.getBoundingClientRect(), document.documentElement.clientWidth));
  }, [open, tip]);
  useEffect(() => {
    if (!open) return;
    // Capture phase so Esc hides the tip before anything else (e.g. the drawer) acts on it.
    const key = (e) => { if (e.key === 'Escape') { e.stopPropagation(); setOpen(false); } };
    const away = (e) => { if (!ref.current?.contains(e.target)) setOpen(false); };
    const hide = () => setOpen(false);
    addEventListener('keydown', key, true); addEventListener('pointerdown', away); addEventListener('scroll', hide, true);
    return () => { removeEventListener('keydown', key, true); removeEventListener('pointerdown', away); removeEventListener('scroll', hide, true); };
  }, [open]);
  if (!tip) return children;
  const c = children.props, on = (f, g) => (e) => { f?.(e); g(e); };
  return <>
    {cloneElement(children, {
      ref, 'aria-describedby': describe ? id : undefined,
      onPointerEnter: on(c.onPointerEnter, (e) => e.pointerType === 'mouse' && setOpen(true)),
      onPointerLeave: on(c.onPointerLeave, (e) => e.pointerType === 'mouse' && setOpen(false)),
      onFocus: on(c.onFocus, (e) => e.target === ref.current && e.target.matches(':focus-visible') && setOpen(true)),
      onBlur: on(c.onBlur, () => setOpen(false)),
      onClick: on(c.onClick, () => setOpen((o) => tap && !o)), // a click acts, so drop the tip; `tap` toggles it instead
    })}
    {(open || describe) && createPortal(
      <span ref={box} role="tooltip" id={id} hidden={!open} style={pos ? { left: pos.left, top: pos.top } : { left: 0, top: 0, visibility: 'hidden' }}
        className="pointer-events-none fixed z-[60] max-w-[min(18rem,calc(100vw-16px))] rounded-md bg-fg px-2 py-1 text-xs leading-snug text-bg shadow-lg">
        {tip}
      </span>, document.body)}
  </>;
}
