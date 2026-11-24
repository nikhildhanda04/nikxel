import { contextBridge, ipcRenderer } from "electron";

/// Bridge for the setup wizard (main/system/onboarding.ts). Its page is the
/// Mac's (src/OnboardingPage.swift), which posts every message through
/// WKWebView's `webkit.messageHandlers.nx`; the same object is given here.
/// Main answers with `nx.state(...)`, `nx.frames(...)` and `nx.progress(...)`.
contextBridge.exposeInMainWorld("webkit", {
  messageHandlers: {
    nx: { postMessage: (m: unknown) => ipcRenderer.send("onboarding:action", m) },
  },
});
