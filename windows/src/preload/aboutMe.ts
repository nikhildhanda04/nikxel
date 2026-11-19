import { contextBridge, ipcRenderer } from "electron";

/// Bridge for the About Me window (see main/system/aboutMe.ts).
contextBridge.exposeInMainWorld("nikxelAbout", {
  load: () => ipcRenderer.invoke("about:load"),
  save: (text: string) => ipcRenderer.invoke("about:save", text),
  voice: (pcm: Uint8Array) => ipcRenderer.invoke("about:voice", pcm),
});
