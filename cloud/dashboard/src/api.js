async function call(method, path, body) {
  const r = await fetch('/api' + path, {
    method, credentials: 'include',
    headers: body === undefined ? {} : { 'content-type': 'application/json' },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const json = await r.json().catch(() => null);
  if (!r.ok) throw Object.assign(new Error(json?.error || r.statusText), { status: r.status });
  return json;
}

export const api = {
  me: () => call('GET', '/me'),
  devLogin: (userId) => call('POST', '/dev/login', { userId }),
  logout: () => call('POST', '/auth/logout'),
  createOrg: (name) => call('POST', '/orgs', { name }),
  joinOrg: (token) => call('POST', '/orgs/join', { token }),
  invite: (role) => call('POST', '/invites', { role }),
  members: () => call('GET', '/members'),
  setRole: (userId, role) => call('PATCH', `/members/${encodeURIComponent(userId)}`, { role }),
  pairingCode: () => call('GET', '/pairing-code'),
  mine: () => call('GET', '/summaries/mine'),
  rollup: () => call('GET', '/rollup'),
};

// Item type -> label, CSS color var (index.css), and a 24x24 SVG path. Plain JS so node --test can import it.
const TYPES = {
  coding: ['Coding', 'M8 7l-5 5 5 5M16 7l5 5-5 5'],
  shipped: ['Shipped', 'M12 3c3 2 5 6 5 10l-2 3H9l-2-3c0-4 2-8 5-10zM9 16l-2 5 3-2M15 16l2 5-3-2'],
  meeting: ['Meeting', 'M3 7h12v10H3zM15 10l6-3v10l-6-3'],
  research: ['Research', 'M10 4a6 6 0 100 12 6 6 0 000-12zM15 15l5 5'],
  learning: ['Learning', 'M3 6c3-1 6-1 9 1 3-2 6-2 9-1v12c-3-1-6-1-9 1-3-2-6-2-9-1zM12 7v12'],
  writing: ['Writing', 'M4 20l4-1 11-11-3-3L5 16zM14 6l3 3'],
  review: ['Review', 'M2 12s4-7 10-7 10 7 10 7-4 7-10 7-10-7-10-7zM12 9a3 3 0 100 6 3 3 0 000-6z'],
  planning: ['Planning', 'M4 5h16v15H4zM4 10h16M9 3v4M15 3v4'],
  comms: ['Comms', 'M4 5h16v11H9l-5 4z'],
  other: ['Other', 'M6 12h.01M12 12h.01M18 12h.01'],
};
export const TYPE_ORDER = Object.keys(TYPES);
export const typeMeta = (type) => {
  const k = TYPES[type] ? type : 'other';
  return { label: TYPES[k][0], color: `var(--t-${k})`, icon: TYPES[k][1] };
};
