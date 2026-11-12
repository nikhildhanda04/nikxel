import { contextBridge, ipcRenderer } from "electron";

/// The avatar page's whole link to main: one channel each way. Message shapes
/// are ToRenderer / FromRenderer in src/main/avatar/avatarWindow.ts.
contextBridge.exposeInMainWorld("nikxel", {
  onMessage(cb: (msg: unknown) => void): void {
    ipcRenderer.on("avatar:msg", (_e, msg) => cb(msg));
    // Keystrokes may also arrive bare on their own channel (main.ts sends
    // them straight from InputHandler); same as { type: "key" }.
    ipcRenderer.on("avatar:keystroke", () => cb({ type: "key" }));
  },
  send(evt: unknown): void {
    ipcRenderer.send("avatar:event", evt);
  },
});
