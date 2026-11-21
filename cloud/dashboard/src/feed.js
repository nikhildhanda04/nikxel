// Project feed helpers. Plain JS so node --test can import it.
const isMtg = (i) => (i.section || '').toLowerCase() === 'meetings';

export const splitFeed = (days, mode) => days
  .map((d) => ({
    ...d,
    meetings: mode === 'meetings' ? d.meetings || [] : [],
    items: (d.items || []).filter((i) => isMtg(i) === (mode === 'meetings')),
  }))
  .filter((d) => d.meetings.length || d.items.length);

// Shared meeting bodies are untrusted: callers render these as text nodes only.
export const mdBlocks = (md) => String(md || '').split('\n').map((l) => l.trim()).filter(Boolean).map((l) => {
  if (l.startsWith('#')) return { kind: 'h', text: l.replace(/^#+\s*/, '') };
  if (/^[-*]\s/.test(l)) return { kind: 'li', text: l.slice(2).trim() };
  return { kind: 'p', text: l };
});
