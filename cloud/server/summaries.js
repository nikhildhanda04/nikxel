// Pure summary-integrity logic. No DB. redact/ownerEdit/release mutate and return the summary.
export class ForbiddenError extends Error {
  constructor(msg = 'forbidden') { super(msg); this.name = 'ForbiddenError'; }
}

export function mergeItems(existing, incoming) {
  const byId = new Map(incoming.map(i => [i.id, i]));
  const seen = new Set(existing.map(i => i.id));
  const merged = existing.map(e => {
    const n = byId.get(e.id);
    return n ? { ...e, what: n.what, minutes: n.minutes, removed: e.removed } : e;
  });
  for (const n of incoming) {
    if (!seen.has(n.id)) { seen.add(n.id); merged.push({ ...n, removed: false }); }
  }
  return merged;
}

export function adminView(summary) {
  if (summary.status !== 'released') return null;
  return { ...summary, items: summary.items.filter(i => i.removed === false) };
}

function find(summary, itemId) {
  const item = summary.items.find(i => i.id === itemId);
  if (!item) throw new Error('item not found');
  return item;
}

export function redact(summary, itemId, byRole) {
  if (summary.status !== 'pending') throw new ForbiddenError('summary already released');
  find(summary, itemId).removed = true;
  return summary;
}

export function ownerEdit(summary, itemId, patch, byRole) {
  if (byRole !== 'owner') throw new ForbiddenError('only the owner can edit');
  if (summary.status !== 'pending') throw new ForbiddenError('summary already released');
  const item = find(summary, itemId);
  if (patch.what !== undefined) item.what = patch.what;
  if (patch.minutes !== undefined) item.minutes = patch.minutes;
  return summary;
}

export function release(summary, byRole) {
  if (summary.status === 'pending') summary.status = 'released';
  return summary;
}
