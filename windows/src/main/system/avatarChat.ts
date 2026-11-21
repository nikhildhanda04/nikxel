import { BrowserWindow, ipcMain, Rectangle, screen } from "electron";
import * as path from "path";
import { cblog } from "../core/diag";
import { documentsRoot, nikxelPath, preloadPath, readText, rendererPath, writeAtomic } from "../core/paths";
import { MOMError, MOMGenerator } from "../recording/momGenerator";
import { Transcriber } from "../recording/transcriber";
import { wavHeader } from "../recording/wavWriter";
import { CAP, build, localBlocks, projectBlocks, prompt } from "./chatContext";
import { CloudSync } from "./cloudSync";

/// The small box a single click on the avatar opens: ask about your last two weeks of meetings, days, notes and
/// projects. Clicking the avatar again or Esc closes it, and forgets the conversation. Port of src/AvatarChat.swift.

let current: BrowserWindow | null = null;
let seq = 0;

export function toggle(avatar: Rectangle, agent: MOMGenerator, recording: () => boolean): void {
  if (current && !current.isDestroyed()) { current.close(); return; }

  // Beside the avatar on the side with room, level with it, kept in the work area.
  const W = 320, H = 280, gap = 8;
  const wa = screen.getDisplayMatching(avatar).workArea;
  const x = avatar.x + avatar.width + gap + W <= wa.x + wa.width ? avatar.x + avatar.width + gap : avatar.x - gap - W;
  const y = Math.min(Math.max(avatar.y + avatar.height / 2 - H / 2, wa.y), wa.y + wa.height - H);

  const id = `c${++seq}`;
  const win = new BrowserWindow({
    x: Math.round(x), y: Math.round(y), width: W, height: H,
    frame: false,
    transparent: true,
    alwaysOnTop: true,
    resizable: false,
    minimizable: false,
    maximizable: false,
    skipTaskbar: true,
    show: false,
    webPreferences: { preload: preloadPath("avatarChat"), contextIsolation: true, nodeIntegration: false, sandbox: true },
  });
  current = win;
  const history: { q: string; a: string }[] = [];
  // Fetched once as the box opens, while the user types; every question reuses it.
  const feedP = CloudSync.projectFeed(CloudSync.getter(3000));

  ipcMain.handle(`chat:send:${id}`, async (_e, text: string) => {
    const today = new Date();
    const { feed, offline } = await feedP;
    const context = build([...localBlocks(path.join(documentsRoot(), "nikxel"), today), ...projectBlocks(feed)], CAP);
    let reply: string, error = false;
    try {
      reply = (await agent.runPrompt(prompt(context, history, text, today), "chat", "haiku", 30)).trim();
      history.push({ q: text, a: reply });
    } catch (e) {
      error = true;
      reply = e instanceof MOMError && e.kind === "agentNotFound" ? "Connect Claude in Settings to use chat." : "⚠︎ " + (e as Error).message;
    }
    cblog(`AvatarChat: ${context.length} chars of context`);
    return { text: reply, offline, error };
  });
  // 16 kHz mono 16-bit PCM from the page's mic, as whisper.cpp wants it.
  ipcMain.handle(`chat:voice:${id}`, async (_e, pcm: Uint8Array) => {
    const wav = nikxelPath("edits", "chat-voice.wav");
    writeAtomic(wav, Buffer.concat([wavHeader(pcm.byteLength, 16000, 1), Buffer.from(pcm)]));
    try { return (readText(await new Transcriber().transcribe(wav, "txt")) ?? "").trim(); } catch { return ""; }
  });
  ipcMain.handle(`chat:close:${id}`, () => { if (!win.isDestroyed()) win.close(); });

  // A recording can start or stop while the box is open; the mic follows it.
  const timer = setInterval(() => { if (!win.isDestroyed()) win.webContents.send("chat:recording", recording()); }, 1000);
  win.on("closed", () => {
    clearInterval(timer);
    for (const ch of ["send", "voice", "close"]) ipcMain.removeHandler(`chat:${ch}:${id}`);
    if (current === win) current = null;
  });
  win.once("ready-to-show", () => { win.show(); win.focus(); });
  win.loadFile(rendererPath("avatarChat"), { query: { id, rec: recording() ? "1" : "0" } });
}
