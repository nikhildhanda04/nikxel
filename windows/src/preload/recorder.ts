import { contextBridge, ipcRenderer } from "electron";

/// Bridge for the hidden recorder window (see main/recording/audioRecorder.ts).
/// Main drives start/stop/mute; the page streams 16 kHz mono PCM back.

type Track = "mix" | "mic" | "sys";

contextBridge.exposeInMainWorld("nikxelRecorder", {
  onStart: (cb: (opts: { mode: "notes" | "meeting"; micMuted: boolean }) => void) =>
    ipcRenderer.on("recorder:start", (_e, opts) => cb(opts)),
  onStop: (cb: () => void) => ipcRenderer.on("recorder:stop", () => cb()),
  onMute: (cb: (muted: boolean) => void) => ipcRenderer.on("recorder:mute", (_e, muted: boolean) => cb(muted)),

  started: (info: { tracks: Track[]; inputRate: number }) => ipcRenderer.send("recorder:started", info),
  failed: (err: { stage: string; name: string; message: string }) => ipcRenderer.send("recorder:failed", err),
  micUnavailable: (err: { name: string; message: string }) => ipcRenderer.send("recorder:micUnavailable", err),
  chunk: (track: Track, pcm: Uint8Array) => ipcRenderer.send("recorder:chunk", track, pcm),
  stopped: () => ipcRenderer.send("recorder:stopped"),
  log: (msg: string) => ipcRenderer.send("recorder:log", msg),
});
