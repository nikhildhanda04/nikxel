import { contextBridge, ipcRenderer } from "electron";

/// Bridge for the avatar's chat box (see main/system/avatarChat.ts).

// Preloads compile without the DOM lib; this is the one DOM global used.
declare const location: { search: string };

const id = new URLSearchParams(location.search).get("id") ?? "";

contextBridge.exposeInMainWorld("nikxelChat", {
  send: (text: string) => ipcRenderer.invoke(`chat:send:${id}`, text),
  voice: (pcm: Uint8Array) => ipcRenderer.invoke(`chat:voice:${id}`, pcm),
  close: () => ipcRenderer.invoke(`chat:close:${id}`),
  onRecording: (cb: (on: boolean) => void) => ipcRenderer.on("chat:recording", (_e, on: boolean) => cb(on)),
});
