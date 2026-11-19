import { BrowserWindow, ipcMain } from "electron";
import { cblog } from "../core/diag";
import { nikxelPath, preloadPath, readText, rendererPath, writeAtomic } from "../core/paths";
import { Settings } from "../core/settings";
import { Transcriber } from "../recording/transcriber";
import { wavHeader } from "../recording/wavWriter";

/// "About Me" — a window where the user tells Nikxel who they are, their work,
/// their company and what they're aiming for, by typing or by talking (the mic
/// records, Whisper types it in). Saved to Settings.userContext and fed into
/// the summary, meeting and reply prompts. Mirrors src/AboutMe.swift.

let win: BrowserWindow | null = null;

export function showAboutMe(): void {
  if (win && !win.isDestroyed()) { win.show(); win.focus(); return; }

  const w = new BrowserWindow({
    width: 440,
    height: 520,
    minWidth: 360,
    minHeight: 420,
    title: "About Me",
    show: false,
    autoHideMenuBar: true,
    webPreferences: { preload: preloadPath("aboutMe"), contextIsolation: true, nodeIntegration: false, sandbox: true },
  });
  win = w;

  ipcMain.handle("about:load", () => Settings.userContext);
  ipcMain.handle("about:save", (_e, text: string) => {
    Settings.userContext = text;
    cblog(`AboutMe: context saved (${text.length} chars)`);
    return "saved";
  });
  // 16 kHz mono 16-bit PCM from the page's mic, as whisper.cpp wants it.
  ipcMain.handle("about:voice", async (_e, pcm: Uint8Array) => {
    const wav = nikxelPath("aboutme-voice.wav");
    writeAtomic(wav, Buffer.concat([wavHeader(pcm.byteLength, 16000, 1), Buffer.from(pcm)]));
    try { return (readText(await new Transcriber().transcribe(wav, "txt")) ?? "").trim(); } catch { return ""; }
  });

  w.on("closed", () => {
    for (const ch of ["load", "save", "voice"]) ipcMain.removeHandler(`about:${ch}`);
    if (win === w) win = null;
  });
  w.once("ready-to-show", () => { w.show(); w.focus(); });
  w.loadFile(rendererPath("aboutMe"));
}
