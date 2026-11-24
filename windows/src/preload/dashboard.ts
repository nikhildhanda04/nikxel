import { contextBridge, ipcRenderer } from "electron";

/// Bridge for the Nikxel window (main/system/dashboardWindow.ts). Its page is
/// the Mac's (src/DashboardPage.swift), which posts every message through
/// WKWebView's `webkit.messageHandlers.nx`; the same object is given here.
/// Main answers with `nx.state(...)`, `nx.reply(id, value)` and the like.
///
/// The chat's mic is the one thing done in the page: Electron's main process
/// has no microphone, so this records like the avatar's chat box does, and main
/// only transcribes.

// Preloads compile without the DOM lib; these are the DOM globals used.
/* eslint-disable @typescript-eslint/no-explicit-any */
declare const navigator: any, MediaRecorder: any, AudioContext: any, Blob: any;

let recorder: any = null, stream: any = null, chunks: any[] = [];

async function startMic(): Promise<string> {
  try { stream = await navigator.mediaDevices.getUserMedia({ audio: true }); } catch { return ""; }
  chunks = [];
  recorder = new MediaRecorder(stream);
  recorder.ondataavailable = (e: any) => chunks.push(e.data);
  recorder.start();
  return "recording";
}

/// 16 kHz mono 16-bit PCM, as whisper.cpp wants it.
async function stopMic(): Promise<string> {
  const r = recorder;
  recorder = null;
  await new Promise<void>(res => { r.onstop = () => res(); r.stop(); });
  for (const t of stream?.getTracks() ?? []) t.stop();
  try {
    const ctx = new AudioContext({ sampleRate: 16000 });
    const audio = await ctx.decodeAudioData(await new Blob(chunks).arrayBuffer());
    void ctx.close();
    const f = audio.getChannelData(0), pcm = new Int16Array(f.length);
    for (let i = 0; i < f.length; i++) { const v = Math.max(-1, Math.min(1, f[i])); pcm[i] = v < 0 ? v * 0x8000 : v * 0x7fff; }
    return await ipcRenderer.invoke("dashboard:voice", new Uint8Array(pcm.buffer));
  } catch { return ""; }
}

async function mic(): Promise<string> {
  if (recorder) return stopMic();
  // The meeting recorder has the mic; typing still works.
  if (await ipcRenderer.invoke("dashboard:recording")) return "busy";
  return startMic();
}

contextBridge.exposeInMainWorld("webkit", {
  messageHandlers: {
    nx: {
      postMessage: (m: { type?: string; id?: number }) => {
        if (m?.type === "chatMic") { void mic().then(v => ipcRenderer.send("dashboard:reply", m.id, v)); return; }
        ipcRenderer.send("dashboard:msg", m);
      },
    },
  },
});
