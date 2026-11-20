import { useEffect, useState } from 'react';
import { api } from './api.js';
import { Btn, Muted } from './ui.jsx';
import Login from './screens/Login.jsx';
import Onboarding from './screens/Onboarding.jsx';
import Connect from './screens/Connect.jsx';
import Mine from './screens/Mine.jsx';
import People from './screens/People.jsx';
import Admin from './screens/Admin.jsx';

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
  const tabs = [['mine', 'My summaries'], ['connect', 'Connect app'], ...(admin ? [['people', 'People'], ['admin', 'Admin']] : [])];
  const screen = { mine: <Mine me={me} />, connect: <Connect />, people: admin && <People me={me} />, admin: admin && <Admin /> }[route] || <Mine me={me} />;

  return (
    <Shell>
      <nav className="flex flex-wrap items-baseline gap-x-5 gap-y-1 mb-10 text-sm">
        <span className="font-medium">{me.name}</span>
        <Muted className="mr-auto">{me.role}</Muted>
        {tabs.map(([k, l]) => (
          <a key={k} href={'#' + k} className={route === k ? 'underline underline-offset-4' : 'text-neutral-500'}>{l}</a>
        ))}
      </nav>
      {screen}
    </Shell>
  );
}

const Shell = ({ children }) => <main className="max-w-2xl mx-auto px-4 py-10">{children}</main>;
