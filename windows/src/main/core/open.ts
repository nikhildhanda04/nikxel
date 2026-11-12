import { shell } from "electron";
import * as path from "path";
import { spawn } from "child_process";
import { ensureDir, isWin } from "./paths";
import { diag } from "./diag";

/// Opens a file the way NSWorkspace.openFile did. A fresh Windows install has
/// no app registered for .md/.txt/.json-ish files the user edits, and
/// shell.openPath then fails with "no application is associated"; Notepad is
/// the TextEdit of Windows, so fall back to it.
export async function openFile(file: string): Promise<void> {
  const err = await shell.openPath(file);
  if (!err) return;
  diag("open", `openPath failed for ${file}: ${err}`);
  if (isWin && /\.(md|txt|json|log|jsonl)$/i.test(file)) {
    spawn("notepad.exe", [file], { detached: true, stdio: "ignore", windowsHide: false }).unref();
  }
}

/// Opens a folder in Explorer, creating it first.
export async function openFolder(dir: string): Promise<void> {
  ensureDir(dir);
  await shell.openPath(dir);
}

export function openUrl(url: string): void {
  shell.openExternal(url).catch(e => diag("open", `openExternal failed: ${e}`));
}

/// Explorer with the file selected.
export function revealFile(file: string): void {
  shell.showItemInFolder(path.resolve(file));
}
