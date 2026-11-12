import { contextBridge, ipcRenderer } from "electron";

// Preloads compile without the DOM lib; this is the one DOM global used.
declare const location: { search: string };

const id = new URLSearchParams(location.search).get("id") ?? "";

contextBridge.exposeInMainWorld("nikxelPrompt", {
  init: () => ipcRenderer.invoke(`prompt:init:${id}`),
  answer: (button: number, value: string) => ipcRenderer.send(`prompt:answer:${id}`, { button, value }),
});
