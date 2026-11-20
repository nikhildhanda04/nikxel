import { useEffect, useState } from 'react';
import { api, nextTheme } from './api.js';
import { Icon, pillCls } from './ui.jsx';
import Login from './screens/Login.jsx';
import Onboarding from './screens/Onboarding.jsx';
import Connect from './screens/Connect.jsx';
import Mine from './screens/Mine.jsx';
import People from './screens/People.jsx';
import Team from './screens/Team.jsx';
import Projects from './screens/Projects.jsx';
import Org from './screens/Org.jsx';

const useHash = () => {
  const [h, setH] = useState(location.hash.slice(1) || 'mine');
  useEffect(() => {
    const f = () => setH(location.hash.slice(1) || 'mine');
    addEventListener('hashchange', f);
    return () => removeEventListener('hashchange', f);
  }, []);
  return h;
};

const dec = (s) => { try { return decodeURIComponent(s); } catch { return s; } };

export default function App() {
  const [me, setMe] = useState(undefined); // undefined = loading, null = signed out
  const route = useHash();
  const load = () => api.me().then(setMe, () => setMe(null));
  useEffect(() => { load(); }, []);

  if (me === undefined) return null;
  if (me === null) return <Shell><Login onDone={load} /></Shell>;
  if (!me.orgId) return <Shell><Onboarding onDone={load} /></Shell>;

  const admin = me.role === 'admin' || me.role === 'owner';
  const tabs = [['mine', 'My days'], ...(admin ? [['team', 'Team'], ['projects', 'Projects'], ['people', 'People'], ['org', 'Org']] : []), ['connect', 'Connect']];
  const [base, sub] = route.split('/'); // #projects/<encoded name>
  const tab = tabs.some(([k]) => k === base) ? base : 'mine';
  const screen = { mine: <Mine />, connect: <Connect />, team: <Team />, projects: <Projects key={route} name={sub === undefined ? undefined : dec(sub)} />, people: <People me={me} />, org: <Org /> }[tab];
  const logout = () => api.logout().finally(() => { location.hash = ''; setMe(null); });

  return (
    <Shell right={<>
      <span className="min-w-0 truncate text-sm text-muted">{me.name}<span className="hidden sm:inline"> · {me.role}</span></span>
      <button onClick={logout} className={pillCls}>Log out</button>
    </>}>
      <nav className="mb-8 flex gap-5 overflow-x-auto text-sm">
        {tabs.map(([k, l]) => (
          <a key={k} href={'#' + k} aria-current={tab === k ? 'page' : undefined}
            className="whitespace-nowrap py-1 text-muted transition-colors hover:text-fg aria-[current=page]:text-fg aria-[current=page]:font-medium">{l}</a>
        ))}
      </nav>
      {screen}
    </Shell>
  );
}

// lafda's frame: h-14 header (wordmark left, theme toggle + pill right) over a ~640px column.
const Shell = ({ right, children }) => (
  <div className="max-w-2xl mx-auto px-4">
    <header className="flex h-14 items-center gap-2">
      <a href="#mine" className="mr-auto shrink-0 font-heading text-2xl font-bold tracking-tight">nikxel</a>
      <ThemeToggle />
      {right}
    </header>
    <main className="pt-6 pb-16">{children}</main>
  </div>
);

// Follows the system until clicked; the choice is then remembered.
const sysTheme = () => (matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light');
function ThemeToggle() {
  const cur = () => document.documentElement.dataset.theme || sysTheme();
  const [t, setT] = useState(cur);
  useEffect(() => { // keep the icon right if the system flips while no override is set
    const m = matchMedia('(prefers-color-scheme: dark)'), f = () => setT(cur());
    m.addEventListener('change', f);
    return () => m.removeEventListener('change', f);
  }, []);
  const flip = () => {
    const n = nextTheme(cur());
    document.documentElement.dataset.theme = n;
    try { localStorage.setItem('theme', n); } catch {}
    setT(n);
  };
  return (
    <button onClick={flip} aria-label={`Switch to ${nextTheme(t)} mode`} className="inline-flex size-9 items-center justify-center rounded-full text-fg/80 transition-colors hover:bg-accent hover:text-fg">
      <Icon className="size-[18px]" d={t === 'dark'
        ? 'M12 3v1M12 20v1M4.2 4.2l.7.7M19.1 19.1l.7.7M3 12h1M20 12h1M4.2 19.8l.7-.7M19.1 4.9l.7-.7M12 8a4 4 0 100 8 4 4 0 000-8z'
        : 'M20 14.5A8 8 0 019.5 4 8 8 0 1020 14.5z'} />
    </button>
  );
}
