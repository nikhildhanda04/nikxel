import { H, Muted, Btn } from '../ui.jsx';

const DOWNLOAD = import.meta.env.VITE_NIKXEL_DOWNLOAD_URL || 'https://nikxel.app/download';

export default function Install() {
  return (
    <div className="max-w-md">
      <H>Install Nikxel</H>
      <Muted className="mb-4">Nikxel runs on your computer and writes your nightly summary. Install it, then connect it to this org.</Muted>
      <div className="flex flex-wrap gap-2">
        <a href={DOWNLOAD} target="_blank" rel="noreferrer" className="inline-flex h-8 items-center rounded-full bg-fg px-3.5 text-sm font-medium text-bg transition-opacity hover:opacity-85">Download Nikxel</a>
        <Btn onClick={() => { location.hash = 'connect'; }}>Connect</Btn>
      </div>
    </div>
  );
}
