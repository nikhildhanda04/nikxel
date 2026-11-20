import { useEffect, useState } from 'react';
import { api } from './api.js';
import Login from './screens/Login.jsx';
import Onboarding from './screens/Onboarding.jsx';
import Connect from './screens/Connect.jsx';
import Mine from './screens/Mine.jsx';
import People from './screens/People.jsx';
import Team from './screens/Team.jsx';

const useHash = () => {
  const [h, setH] = useState(location.hash.slice(1) || 'mine');
  useEffect(() => {
    const f = () => setH(location.hash.slice(1) || 'mine');
    addEventListener('hashchange', f);
    return () => removeEventListener('hashchange', f);
  }, []);
  return h;
};

export default function App() {
  const [me, setMe] = useState(undefined); // undefined = loading, null = signed out
  const route = useHash();
  const load = () => api.me().then(setMe, () => setMe(null));
  useEffect(() => { load(); }, []);

  if (me === undefined) return null;
  if (me === null) return <Shell><Login onDone={load} /></Shell>;
  if (!me.orgId) return <Shell><Onboarding onDone={load} /></Shell>;

  const admin = me.role === 'admin' || me.role === 'owner';
  const tabs = [['mine', 'My days'], ...(admin ? [['team', 'Team'], ['people', 'People']] : []), ['connect', 'Connect']];
  const tab = tabs.some(([k]) => k === route) ? route : 'mine';
  const screen = { mine: <Mine />, connect: <Connect />, team: <Team />, people: <People me={me} /> }[tab];
  const logout = () => api.logout().finally(() => { location.hash = ''; setMe(null); });

  return (
    <Shell>
      <header className="mb-10">
        <div className="flex items-center gap-3 mb-4">
          <span className="font-serif text-2xl font-extrabold tracking-tight mr-auto">Nikxel</span>
          <span className="text-sm text-muted truncate">{me.name} · {me.role}</span>
          <button onClick={logout} className="rounded-full border border-line px-3 py-1 text-sm hover:border-accent">Log out</button>
        </div>
        <nav className="flex gap-1 overflow-x-auto border-b border-line text-sm">
          {tabs.map(([k, l]) => (
            <a key={k} href={'#' + k} aria-current={tab === k ? 'page' : undefined}
              className="-mb-px border-b-2 border-transparent px-3 py-2 text-muted hover:text-ink aria-[current=page]:border-accent aria-[current=page]:text-ink aria-[current=page]:font-medium">{l}</a>
          ))}
        </nav>
      </header>
      {screen}
    </Shell>
  );
}

const Shell = ({ children }) => <main className="max-w-3xl mx-auto px-4 py-8 sm:py-12">{children}</main>;
