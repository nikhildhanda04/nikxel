import { contextBridge, ipcRenderer } from "electron";

/// Bridge for the first-run tour's pointer card (main/system/coachTour.ts).
/// The page is the Mac's (src/CoachPage.swift) and posts through
/// WKWebView's `webkit.messageHandlers.nx`; the same object is given here.
contextBridge.exposeInMainWorld("webkit", {
  messageHandlers: {
    nx: { postMessage: (m: unknown) => ipcRenderer.send("coach:msg", m) },
  },
});
