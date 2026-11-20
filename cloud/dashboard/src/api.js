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

export const canEditFacts = (role) => role === 'owner';

export const api = {
  me: () => call('GET', '/me'),
  devLogin: (userId) => call('POST', '/dev/login', { userId }),
  createOrg: (name) => call('POST', '/orgs', { name }),
  joinOrg: (token) => call('POST', '/orgs/join', { token }),
  invite: (role) => call('POST', '/invites', { role }),
  members: () => call('GET', '/members'),
  pairingCode: () => call('GET', '/pairing-code'),
  mine: () => call('GET', '/summaries/mine'),
  redact: (id, itemId) => call('POST', `/summaries/${id}/redact`, { itemId }),
  release: (id) => call('POST', `/summaries/${id}/release`),
  editItem: (id, itemId, patch) => call('PATCH', `/summaries/${id}/items/${itemId}`, patch),
  rollup: () => call('GET', '/rollup'),
};
