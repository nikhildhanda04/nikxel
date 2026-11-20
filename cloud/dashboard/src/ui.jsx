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
