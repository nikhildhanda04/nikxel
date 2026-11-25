import { BrowserWindow, ipcMain, Rectangle, screen, Tray } from "electron";
import { diag } from "../core/diag";
import { preloadPath, rendererPath } from "../core/paths";
import { powershell } from "../core/proc";
import { Settings } from "../core/settings";

/// Port of CoachTour.swift: a pointer card (src/CoachPage.swift) in a small
/// transparent window beside something on screen, with an arrow at it, and
/// the first-run tour built from it.

export interface Card { title: string; text: string; step?: number; total?: number; primary?: string }

let ipcReady = false;
const pointers = new Set<CoachPointer>();

/// One card at a time; `show` again moves it. Picks the side with room.
export class CoachPointer {
  onNext: (() => void) | null = null;
  onSkip: (() => void) | null = null;
  private win: BrowserWindow;
  private loaded = false;
  private pending: [Rectangle, Card] | null = null;
  private target: Rectangle = { x: 0, y: 0, width: 0, height: 0 };
  private card: Card = { title: "", text: "" };
  private size = { w: 380, h: 200 };

  constructor() {
    if (!ipcReady) {
      ipcReady = true;
      ipcMain.on("coach:msg", (e, m: { type?: string; w?: number; h?: number }) => {
        for (const p of pointers) if (!p.win.isDestroyed() && e.sender === p.win.webContents) p.message(m);
      });
    }
    this.win = new BrowserWindow({
      width: 380, height: 200, frame: false, transparent: true, resizable: false, movable: false,
      skipTaskbar: true, hasShadow: false, show: false, alwaysOnTop: true, focusable: true,
      webPreferences: { preload: preloadPath("coach"), contextIsolation: true, nodeIntegration: false },
    });
    // Above the taskbar and the avatar.
    this.win.setAlwaysOnTop(true, "screen-saver");
    this.win.webContents.on("did-finish-load", () => {
      this.loaded = true;
      if (this.pending) { const [t, c] = this.pending; this.pending = null; this.show(t, c); }
    });
    void this.win.loadFile(rendererPath("coach"));
    pointers.add(this);
  }

  show(target: Rectangle, card: Card): void {
    if (this.win.isDestroyed()) return;
    if (!this.loaded) { this.pending = [target, card]; return; }
    const same = JSON.stringify([target, card]) === JSON.stringify([this.target, this.card]);
    if (same && this.win.isVisible()) return;
    this.target = target; this.card = card;
    this.place(true);
    this.win.showInactive();
  }

  close(): void {
    pointers.delete(this);
    if (!this.win.isDestroyed()) this.win.destroy();
  }

  private message(m: { type?: string; w?: number; h?: number }): void {
    if (m.type === "next") this.onNext?.();
    else if (m.type === "skip") this.onSkip?.();
    else if (m.type === "size" && m.w && m.h && (Math.abs(m.h - this.size.h) > 1 || Math.abs(m.w - this.size.w) > 1)) {
      this.size = { w: Math.ceil(m.w), h: Math.ceil(m.h) };
      this.place(false);
    }
  }

  /// Below the target if there's room (arrow up), else above, else beside.
  /// Screen coordinates here run down from the top, unlike the Mac's.
  private place(send: boolean): void {
    const t = this.target, v = screen.getDisplayMatching(t).workArea, gap = 4, { w, h } = this.size;
    let dir: string, x: number, y: number;
    // Near a left or right edge the card can't sit centred under the target,
    // and the arrow would hang off its side: go beside it instead.
    const cx = t.x + t.width / 2, nearEdge = cx - v.x < 60 || v.x + v.width - cx < w - 60;
    if (nearEdge && v.x + v.width - (t.x + t.width) > w + 20) { dir = "left"; x = t.x + t.width + gap; y = t.y + t.height / 2 - 40; }
    else if (nearEdge && t.x - v.x > w + 20 && t.y + t.height <= v.y + v.height) { dir = "right"; x = t.x - gap - w; y = t.y + t.height / 2 - 40; }
    else if (v.y + v.height - (t.y + t.height) > h + 40) { dir = "up"; x = t.x + t.width / 2 - 40; y = t.y + t.height + gap; }
    else if (t.y - v.y > h + 40) { dir = "down"; x = t.x + t.width / 2 - 40; y = t.y - gap - h; }
    else if (v.x + v.width - (t.x + t.width) > w + 20) { dir = "left"; x = t.x + t.width + gap; y = t.y + t.height / 2 - 40; }
    else { dir = "right"; x = t.x - gap - w; y = t.y + t.height / 2 - 40; }
    // The tray sits on the taskbar, outside the work area: allow the card right up to it.
    const display = screen.getDisplayMatching(t).bounds;
    x = Math.min(Math.max(x, v.x + 8), v.x + v.width - w - 8);
    y = Math.min(Math.max(y, display.y + 8), display.y + display.height - h - 8);
    const horizontal = dir === "up" || dir === "down";
    const at = Math.min(Math.max(horizontal ? t.x + t.width / 2 - x : t.y + t.height / 2 - y, 48), (horizontal ? w : h) - 48);
    this.win.setBounds({ x: Math.round(x), y: Math.round(y), width: w, height: h });
    if (!send) return;
    const s = { dir, at, title: this.card.title, text: this.card.text, step: this.card.step ?? 0, total: this.card.total ?? 1, primary: this.card.primary ?? "Next" };
    void this.win.webContents.executeJavaScript(`nx.show(${JSON.stringify(s)})`).catch(() => {});
  }
}

/// Where the tray icon is, or, when Windows has tucked it under the ^ by the
/// clock (Tray.getBounds then points into the overflow or nowhere), roughly
/// where that ^ is. `hidden` says which, for the card's wording.
export function trayTarget(tray: Tray | null): { rect: Rectangle; hidden: boolean } {
  const d = screen.getPrimaryDisplay(), b = d.bounds, wa = d.workArea;
  try {
    const r = tray?.getBounds();
    // On the taskbar: inside the screen but outside the work area.
    if (r && r.width > 0 && r.x >= b.x && r.x < b.x + b.width && (r.y >= wa.y + wa.height || r.y + r.height <= wa.y || r.x >= wa.x + wa.width)) {
      return { rect: r, hidden: false };
    }
  } catch { /* no bounds on this Windows */ }
  // Taskbar at the bottom (the default): the ^ sits left of the clock and the system icons.
  const bar = Math.max(40, b.y + b.height - (wa.y + wa.height));
  return { rect: { x: b.x + b.width - 290, y: wa.y + wa.height + (bar - 28) / 2, width: 28, height: 28 }, hidden: true };
}

/// A window found by its title (the Claude setup's PowerShell), in screen
/// coordinates, or null. Physical pixels from Win32, turned into Electron's.
export async function windowRectByTitle(title: string): Promise<Rectangle | null> {
  const q = title.replace(/'/g, "''");
  const r = await powershell(`
Add-Type -Namespace Nx -Name W -MemberDefinition '[DllImport("user32.dll")] public static extern bool SetProcessDPIAware(); [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern System.IntPtr FindWindow(string c, string t); [DllImport("user32.dll")] public static extern bool GetWindowRect(System.IntPtr h, out RECT r); public struct RECT { public int L; public int T; public int R; public int B; }'
[void][Nx.W]::SetProcessDPIAware()
$h = [Nx.W]::FindWindow($null, '${q}')
if ($h -eq [System.IntPtr]::Zero) { exit 1 }
$r = New-Object Nx.W+RECT
[void][Nx.W]::GetWindowRect($h, [ref]$r)
"$($r.L) $($r.T) $($r.R) $($r.B)"`, { timeoutMs: 8000 }).catch(() => null);
  const m = r && r.code === 0 ? /(-?\d+) (-?\d+) (-?\d+) (-?\d+)/.exec(r.stdout) : null;
  if (!m) return null;
  const [l, t, rr, bb] = m.slice(1).map(Number);
  return screen.screenToDipRect(null, { x: l, y: t, width: rr - l, height: bb - t });
}

export interface TourHost {
  avatarRect(): Rectangle;
  showAvatar(): void;
  tray(): Tray | null;
  openDashboard(): void;
  /// In a call or recording: the tour waits.
  busy(): boolean;
}

let tour: CoachPointer | null = null;

/// The first-run tour: arrows at the avatar and at the tray icon (or the ^
/// hiding it), then the Nikxel window, whose page points at its own sections.
/// Once; Advanced → "Show me around again" replays it.
export const CoachTour = {
  /// Not in the middle of a call or a recording: it waits until both are over.
  startIfNew(host: TourHost): void {
    if (Settings.tourDone) return;
    if (host.busy()) { setTimeout(() => CoachTour.startIfNew(host), 60_000); return; }
    CoachTour.start(host);
  },

  start(host: TourHost): void {
    if (tour) return;
    host.showAvatar();
    const p = new CoachPointer();
    tour = p;
    let step = 0;
    const total = 3;
    const finish = () => {
      Settings.tourDone = true;
      p.close(); tour = null;
      diag("CoachTour", `finished at step ${step + 1} of ${total}`);
    };
    const render = () => {
      const t = trayTarget(host.tray());
      if (step === 0) {
        p.show(host.avatarRect(), { title: "This is me, Nikxel", step, total,
          text: "<p><b>Click</b> me to chat. <b>Double-click</b> me to record a meeting.</p><p><b>Drag</b> me anywhere you like.</p>" });
      } else if (step === 1) {
        p.show(t.rect, { title: "Find me by the clock", step, total, text: t.hidden
          ? "<p>My icon is in the tray. If you can’t see it, click the <b>^</b> arrow here.</p><p>Then drag my icon onto the taskbar so it’s always there.</p>"
          : "<p>My icon in the tray. Click it to record, mute, or open everything else.</p>" });
      } else {
        p.show(t.rect, { title: "Everything else is in the Nikxel window", step, total, primary: "Open it",
          text: "<p>Your meeting notes, chat, tasks and settings. Click my tray icon, then <b>Open Nikxel…</b>. Let me show you around it.</p>" });
      }
    };
    p.onNext = () => {
      step++;
      if (step < total) { render(); return; }
      finish();
      host.openDashboard();
    };
    p.onSkip = finish;
    render();
  },

  /// Replays both tours, from Advanced → "Show me around again".
  replay(host: TourHost): void {
    Settings.tourDone = false;
    Settings.dashboardTourDone = false;
    CoachTour.start(host);
  },
};
