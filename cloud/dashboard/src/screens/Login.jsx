import { api } from '../api.js';
import { Btn, Muted } from '../ui.jsx';

// Dev seed users (cloud/server/seed.js); only rendered in dev builds.
const DEV = [['dev-jake', 'Jake'], ['dev-asha', 'Asha'], ['dev-ben', 'Ben'], ['dev-cleo', 'Cleo']];

export default function Login({ onDone }) {
  return (
    <div>
      <h1 className="font-heading text-2xl md:text-3xl leading-tight font-semibold tracking-tight text-balance">Your team's days, in one place</h1>
      <p className="mt-2 mb-6 text-muted">Sign in to see the days you send from Nikxel.</p>
      <a href="/api/auth/google" className="inline-flex h-9 items-center rounded-full bg-fg px-4 text-sm font-medium text-bg hover:opacity-85">Sign in with Google</a>
      {import.meta.env.DEV && (
        <div className="mt-10 space-y-2 rounded-xl border border-line bg-card p-4">
          <Muted>Dev only</Muted>
          {DEV.map(([id, n]) => <div key={id}><Btn onClick={() => api.devLogin(id).then(onDone)}>Dev sign-in as {n}</Btn></div>)}
        </div>
      )}
    </div>
  );
}
