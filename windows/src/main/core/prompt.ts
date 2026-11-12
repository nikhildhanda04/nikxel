import { BrowserWindow, ipcMain } from "electron";
import { preloadPath, rendererPath } from "./paths";

/// A small modal window with a message, a text field and buttons — what the
/// Mac app did with an NSAlert carrying an NSTextField accessory view. Electron
/// has no built-in text prompt.

export interface PromptOptions {
  title: string;
  message?: string;
  placeholder?: string;
  value?: string;
  /// First is the default (Enter). The last is treated as Cancel (Esc).
  buttons: string[];
  /// Multi-line text area instead of a one-line field (for pasting JSON).
  multiline?: boolean;
}

export interface PromptResult {
  /// Index into buttons; the cancel index when the window was closed.
  button: number;
  value: string;
}

let seq = 0;

export function promptText(opts: PromptOptions): Promise<PromptResult> {
  return new Promise(resolve => {
    const id = `p${++seq}`;
    const win = new BrowserWindow({
      width: 460,
      height: opts.multiline ? 360 : 220,
      resizable: false,
      minimizable: false,
      maximizable: false,
      alwaysOnTop: true,
      title: "Nikxel",
      show: false,
      autoHideMenuBar: true,
      webPreferences: { preload: preloadPath("prompt"), contextIsolation: true, nodeIntegration: false, sandbox: true },
    });
    let done = false;
    const finish = (r: PromptResult) => {
      if (done) return;
      done = true;
      ipcMain.removeHandler(`prompt:init:${id}`);
      ipcMain.removeAllListeners(`prompt:answer:${id}`);
      if (!win.isDestroyed()) win.close();
      resolve(r);
    };
    ipcMain.handle(`prompt:init:${id}`, () => opts);
    ipcMain.once(`prompt:answer:${id}`, (_e, r: PromptResult) => finish(r));
    win.on("closed", () => finish({ button: opts.buttons.length - 1, value: "" }));
    win.once("ready-to-show", () => { win.show(); win.focus(); });
    win.loadFile(rendererPath("prompt"), { query: { id } });
  });
}
