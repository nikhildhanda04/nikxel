export const Btn = ({ primary, className = '', ...p }) => (
  <button {...p} className={`rounded-full border px-3.5 py-1.5 text-sm transition-colors disabled:opacity-40 ${primary ? 'bg-accent border-accent text-surface hover:opacity-90' : 'border-line bg-surface hover:border-accent'} ${className}`} />
);
export const Input = (p) => <input {...p} className={`rounded-lg border border-line bg-surface px-3 py-1.5 w-full min-w-0 ${p.className || ''}`} />;
export const Muted = ({ children, className = '' }) => <p className={`text-sm text-muted ${className}`}>{children}</p>;
export const H = ({ children }) => <h2 className="font-serif text-xl font-semibold mb-4">{children}</h2>;
export const Icon = ({ d, className = 'size-3.5' }) => (
  <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true" className={`shrink-0 ${className}`}><path d={d} /></svg>
);
