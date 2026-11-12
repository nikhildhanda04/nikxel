import * as fs from "fs";
import * as os from "os";
import * as path from "path";

export const isWin = process.platform === "win32";
export const HOME = os.homedir();

/// ~/.nikxel — settings, prompts, logs, models. The same layout as the Mac
/// app, so a user moving between the two recognises every file.
export const NIKXEL_DIR = path.join(HOME, ".nikxel");

export function ensureDir(dir: string): string {
  try { fs.mkdirSync(dir, { recursive: true }); } catch { /* exists or unwritable; callers find out on write */ }
  return dir;
}

export function nikxelPath(...parts: string[]): string {
  ensureDir(NIKXEL_DIR);
  return path.join(NIKXEL_DIR, ...parts);
}

/// The user's Documents folder. On Windows this is often redirected into
/// OneDrive, so ask Electron rather than assuming ~/Documents.
export function documentsRoot(): string {
  try {
    // Lazy: this module is also loaded by checks that run under plain Node.
    // eslint-disable-next-line @typescript-eslint/no-var-requires
    const { app } = require("electron");
    if (app?.getPath) return app.getPath("documents");
  } catch { /* not in Electron */ }
  return path.join(HOME, "Documents");
}

/// ~/Documents/nikxel/<sub> — notes, meetings, daily summaries.
export function documentsDir(sub: "notes" | "meetings" | "daily" | string): string {
  return ensureDir(path.join(documentsRoot(), "nikxel", sub));
}

/// Bundled resources (sprites.png, sprite_prompt.txt, fonts, google_client.json).
/// Packaged: <install>/resources/resources. Dev: windows/resources.
export function resourcesDir(): string {
  const packaged = path.join(process.resourcesPath ?? "", "resources");
  if (process.resourcesPath && fs.existsSync(packaged)) return packaged;
  return path.join(__dirname, "..", "..", "..", "resources");
}

export function resourcePath(name: string): string {
  return path.join(resourcesDir(), name);
}

/// Root of the windows/ app folder in a source checkout (where package.json
/// lives), or null when running from an installed build.
export function appSourceRoot(): string | null {
  const root = path.join(__dirname, "..", "..", "..");
  return fs.existsSync(path.join(root, "package.json")) && fs.existsSync(path.join(root, "src")) ? root : null;
}

export function expandTilde(p: string): string {
  if (p === "~") return HOME;
  if (p.startsWith("~/") || p.startsWith("~\\")) return path.join(HOME, p.slice(2));
  return p;
}

export function readText(file: string): string | null {
  try { return fs.readFileSync(file, "utf8"); } catch { return null; }
}

/// Write-then-rename, like Swift's `.atomic`.
export function writeAtomic(file: string, data: string | Buffer): void {
  ensureDir(path.dirname(file));
  const tmp = `${file}.${process.pid}.tmp`;
  fs.writeFileSync(tmp, data);
  fs.renameSync(tmp, file);
}

export function appendLine(file: string, line: string): void {
  try {
    ensureDir(path.dirname(file));
    fs.appendFileSync(file, line.endsWith("\n") ? line : line + "\n");
  } catch { /* logging must never throw */ }
}

/// yyyy-MM-dd in local time.
export function dayStamp(d: Date = new Date()): string {
  const p = (n: number) => String(n).padStart(2, "0");
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}`;
}

/// yyyy-MM-dd_HH-mm-ss in local time — file-name safe on Windows (no colons).
export function fileStamp(d: Date = new Date()): string {
  const p = (n: number) => String(n).padStart(2, "0");
  return `${dayStamp(d)}_${p(d.getHours())}-${p(d.getMinutes())}-${p(d.getSeconds())}`;
}

/// Compiled preload script for a window: dist/preload/<name>.js.
export function preloadPath(name: string): string {
  return path.join(__dirname, "..", "..", "preload", `${name}.js`);
}

/// Compiled renderer page: dist/renderer/<name>.html.
export function rendererPath(name: string): string {
  return path.join(__dirname, "..", "..", "renderer", `${name}.html`);
}
