import { contextBridge, ipcRenderer, IpcRendererEvent } from "electron";

/// The setup wizard page's only line to the main process: it receives the
/// whole wizard state to render, and sends back what was clicked.
contextBridge.exposeInMainWorld("onboarding", {
  onState(cb: (state: unknown) => void): void {
    ipcRenderer.on("onboarding:state", (_e: IpcRendererEvent, state: unknown) => cb(state));
  },
  send(action: unknown): void {
    ipcRenderer.send("onboarding:action", action);
  },
});
