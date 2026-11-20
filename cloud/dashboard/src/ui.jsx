export const Btn = ({ primary, className = '', ...p }) => (
  <button {...p} className={`border px-3 py-1.5 text-sm disabled:opacity-40 ${primary ? 'bg-neutral-900 border-neutral-900 text-white' : 'border-neutral-300'} ${className}`} />
);
export const Input = (p) => <input {...p} className={`border border-neutral-300 px-3 py-1.5 w-full ${p.className || ''}`} />;
export const Muted = ({ children, className = '' }) => <p className={`text-sm text-neutral-500 ${className}`}>{children}</p>;
export const H = ({ children }) => <h2 className="text-lg font-medium mb-4">{children}</h2>;
