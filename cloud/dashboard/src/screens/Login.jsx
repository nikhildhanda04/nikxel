import { api } from '../api.js';
import { Btn, Muted } from '../ui.jsx';

// Dev seed users (cloud/server/seed.js); only rendered in dev builds.
const DEV = [['dev-jake', 'Jake'], ['dev-asha', 'Asha'], ['dev-ben', 'Ben'], ['dev-cleo', 'Cleo']];

export default function Login({ onDone }) {
  return (
    <div>
      <h1 className="text-2xl font-medium mb-6">Nikxel</h1>
      <a href="/api/auth/google" className="inline-block bg-neutral-900 text-white px-3 py-1.5 text-sm">Sign in with Google</a>
      {import.meta.env.DEV && (
        <div className="mt-10 space-y-2">
          <Muted>Dev only</Muted>
          {DEV.map(([id, n]) => <div key={id}><Btn onClick={() => api.devLogin(id).then(onDone)}>Dev sign-in as {n}</Btn></div>)}
        </div>
      )}
    </div>
  );
}
