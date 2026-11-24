import { BrowserWindow, ipcMain, Rectangle, screen } from "electron";
import { nikxelPath, preloadPath, readText, rendererPath, writeAtomic } from "../core/paths";
import { MOMGenerator } from "../recording/momGenerator";
import { Transcriber } from "../recording/transcriber";
import { wavHeader } from "../recording/wavWriter";
import { ChatSession } from "./chatSession";

/// The chat a single click on the avatar opens (no panel, just bubbles and a field floating beside it): ask about your last two weeks of meetings, days, notes and
/// projects. Clicking the avatar again or Esc closes it, and forgets the conversation. Port of src/AvatarChat.swift.

let current: BrowserWindow | null = null;
let seq = 0;
const W = 340, H = 460, gap = 4;

/// Beside the avatar on the side with room (right first), the field level with its bottom, kept in the work area.
/// flip: the box sits left of the avatar, so Nikxel's bubbles go on the right, next to it.
function place(avatar: Rectangle): { x: number; y: number; flip: boolean } {
  const wa = screen.getDisplayMatching(avatar).workArea;
  const right = wa.x + wa.width - (avatar.x + avatar.width), left = avatar.x - wa.x;
  const flip = right < W + gap && left > right;
  const x = Math.min(Math.max(flip ? avatar.x - gap - W : avatar.x + avatar.width + gap, wa.x), wa.x + wa.width - W);
  const y = Math.min(Math.max(avatar.y + avatar.height - H, wa.y), wa.y + wa.height - H);
  return { x: Math.round(x), y: Math.round(y), flip };
}

export function toggle(avatar: Rectangle, pinnedTo: BrowserWindow, agent: MOMGenerator, recording: () => boolean): void {
  if (current && !current.isDestroyed()) { current.close(); return; }

  const { x, y, flip } = place(avatar);
  const id = `c${++seq}`;
  const win = new BrowserWindow({
    x, y, width: W, height: H,
    frame: false,
    transparent: true,
    hasShadow: false,
    alwaysOnTop: true,
    resizable: false,
    minimizable: false,
    maximizable: false,
    skipTaskbar: true,
    show: false,
    webPreferences: { preload: preloadPath("avatarChat"), contextIsolation: true, nodeIntegration: false, sandbox: true },
  });
  current = win;
  // Reads the project feed, WhatsApp and the inbox once as the box opens, while
  // the user types; every question reuses them.
  const session = new ChatSession(agent);

  ipcMain.handle(`chat:send:${id}`, (_e, text: string) => session.send(text));
  // 16 kHz mono 16-bit PCM from the page's mic, as whisper.cpp wants it.
  ipcMain.handle(`chat:voice:${id}`, async (_e, pcm: Uint8Array) => {
    const wav = nikxelPath("edits", "chat-voice.wav");
    writeAtomic(wav, Buffer.concat([wavHeader(pcm.byteLength, 16000, 1), Buffer.from(pcm)]));
    try { return (readText(await new Transcriber().transcribe(wav, "txt")) ?? "").trim(); } catch { return ""; }
  });
  ipcMain.handle(`chat:close:${id}`, () => { if (!win.isDestroyed()) win.close(); });
  // Follows Nikxel when it moves, re-placed each time so it stays on the side with room and in the work area.
  const start = pinnedTo.getBounds();
  const follow = () => {
    if (win.isDestroyed()) return;
    const b = pinnedTo.getBounds();
    const p = place({ ...avatar, x: avatar.x + b.x - start.x, y: avatar.y + b.y - start.y });
    win.setBounds({ x: p.x, y: p.y, width: W, height: H });
    void win.webContents.executeJavaScript(`document.body.classList.toggle("flip", ${p.flip})`);
  };
  pinnedTo.on("move", follow);
  // A clear window still swallows clicks, so it takes them only over the bubbles and field the page reports.
  let hits: number[][] = [], ignoring = false;
  ipcMain.on(`chat:hit:${id}`, (_e, rects: number[][]) => { hits = rects; });
  const hitTimer = setInterval(() => {
    if (win.isDestroyed()) return;
    const c = screen.getCursorScreenPoint(), b = win.getBounds(), px = c.x - b.x, py = c.y - b.y;
    const over = hits.some(([x, y, w, h]) => px >= x && px < x + w && py >= y && py < y + h);
    if (ignoring === over) { ignoring = !over; win.setIgnoreMouseEvents(ignoring); }
  }, 50);

  // A recording can start or stop while the box is open; the mic follows it.
  const timer = setInterval(() => { if (!win.isDestroyed()) win.webContents.send("chat:recording", recording()); }, 1000);
  win.on("closed", () => {
    clearInterval(timer);
    clearInterval(hitTimer);
    pinnedTo.removeListener("move", follow);
    ipcMain.removeAllListeners(`chat:hit:${id}`);
    for (const ch of ["send", "voice", "close"]) ipcMain.removeHandler(`chat:${ch}:${id}`);
    if (current === win) current = null;
  });
  win.once("ready-to-show", () => { win.show(); win.focus(); });
  win.loadFile(rendererPath("avatarChat"), { query: { id, rec: recording() ? "1" : "0", flip: flip ? "1" : "0" } });
}
