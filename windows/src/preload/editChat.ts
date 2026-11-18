import { contextBridge, ipcRenderer } from "electron";

/// Bridge for a page's Edit chat window (see main/system/pageEdit.ts).

// Preloads compile without the DOM lib; this is the one DOM global used.
declare const location: { search: string };

const id = new URLSearchParams(location.search).get("id") ?? "";

contextBridge.exposeInMainWorld("nikxelEdit", {
  send: (text: string) => ipcRenderer.invoke(`edit:send:${id}`, text),
  undo: () => ipcRenderer.invoke(`edit:undo:${id}`),
  voice: (pcm: Uint8Array) => ipcRenderer.invoke(`edit:voice:${id}`, pcm),
});
