import { isWin } from "../core/paths";
import { desktopRequest } from "../system/desktopHelper";
import { bus } from "../core/bus";
import { cblog } from "../core/diag";

/// One look at the desktop: every visible top-level window with its owning
/// process name, and the apps Windows currently lists as using the microphone.
export interface DesktopSnapshot {
  windows: { proc: string; title: string }[];
  /// Key names under CapabilityAccessManager\ConsentStore\microphone (packaged
  /// apps, e.g. "MSTeams_8wekyb3d8bbwe") and its NonPackaged subkey (exe paths
  /// with "#" for "\", e.g. "C:#Program Files#Zoom#bin#Zoom.exe") whose
  /// LastUsedTimeStop is 0 — i.e. holding the mic right now.
  mic: string[];
}

/// Browsers whose window titles carry the active tab's title. The Mac list was
/// Arc, Chrome, Safari, Brave and Edge; these are their Windows process names.
const BROWSERS = new Set(["chrome", "msedge", "brave", "firefox", "opera", "vivaldi", "arc", "chromium"]);

/// A browser window on a Google Meet tab. Same title tests as the Mac.
/// Windows browsers only title a window after its active tab, the same
/// limitation the Mac's AX window titles had (Arc's tab scan has no Windows
/// counterpart: Arc on Windows exposes no AppleScript-like tab API).
export function isMeetTitle(title: string): boolean {
  return title.includes("Google Meet") || title.includes("meet.google.com") || title.startsWith("Meet -");
}

/// Windows only: a native meeting app holding the microphone. The Mac
/// detector only knew Meet in a browser; on Windows Zoom and Teams are the
/// desktop apps most meetings actually happen in, and "has the mic open" is
/// the one signal that separates being in a call from merely having the app
/// running. Nikxel's own recorder never matches: it isn't on this list.
export function isMeetingMicUser(key: string): boolean {
  if (key.includes("#")) {
    const exe = (key.split("#").pop() ?? "").toLowerCase();
    return /^(zoom|teams|ms-teams|msteams|webexmta|ciscocollabhost|atmgr|slack)\.exe$/.test(exe);
  }
  return /zoom|teams|webex/i.test(key);
}

/// Zoom titles its in-call window "Zoom Meeting" / "Zoom Webinar" — enough on
/// its own, even when the user joined muted with the mic not yet opened.
export function isZoomMeetingWindow(proc: string, title: string): boolean {
  return proc.toLowerCase() === "zoom" && /^Zoom (Meeting|Webinar)\b/.test(title.trim());
}

export function detectMeeting(s: DesktopSnapshot): boolean {
  for (const w of s.windows) {
    if (BROWSERS.has(w.proc.toLowerCase()) && isMeetTitle(w.title)) return true;
    if (isZoomMeetingWindow(w.proc, w.title)) return true;
  }
  return s.mic.some(isMeetingMicUser);
}

/// One look at the desktop, or null when the helper can't answer.
async function snapshot(): Promise<DesktopSnapshot | null> {
  const line = await desktopRequest("meet", 20_000);
  if (!line) return null;
  try {
    const obj = JSON.parse(line);
    // ConvertTo-Json writes a one-element array as a bare object/string.
    const arr = (v: unknown) => (Array.isArray(v) ? v : v === null || v === undefined ? [] : [v]);
    return {
      windows: arr(obj.windows)
        .filter((w: any) => w && typeof w === "object")
        .map((w: any) => ({ proc: String(w.proc ?? ""), title: String(w.title ?? "") })),
      mic: arr(obj.mic).map(String),
    };
  } catch {
    return null;
  }
}

export class MeetingDetector {
  static readonly shared = new MeetingDetector();

  private timer: NodeJS.Timeout | null = null;
  private autoDetected = false;
  private _manualOverride = false;
  private _isInMeeting = false;
  private checking = false;

  /// When true, force `isInMeeting` regardless of auto-detection. Used for
  /// offline / in-person meetings where there's no Meet tab to detect.
  get manualOverride(): boolean { return this._manualOverride; }
  set manualOverride(v: boolean) {
    const old = this._manualOverride;
    this._manualOverride = v;
    if (old !== v) this.recomputeState();
  }

  get isInMeeting(): boolean { return this._isInMeeting; }
  private setInMeeting(v: boolean): void {
    if (this._isInMeeting === v) return;
    this._isInMeeting = v;
    cblog(`MeetingDetector: state -> ${v ? "IN MEETING" : "not in meeting"} (auto=${this.autoDetected} manual=${this._manualOverride})`);
    bus.emit("meetingStateChanged", v);
    bus.emit("menuChanged");
  }

  private recomputeState(): void {
    this.setInMeeting(this.autoDetected || this._manualOverride);
  }

  start(): void {
    if (this.timer) return;
    this.check();
    this.timer = setInterval(() => this.check(), 8000);
  }

  stop(): void {
    if (this.timer) clearInterval(this.timer);
    this.timer = null;
    this.autoDetected = false;
    this._manualOverride = false;
    this.setInMeeting(false);
  }

  private check(): void {
    // Detection reads Win32 windows and the Windows registry; elsewhere (a
    // dev build on a Mac) only the manual override applies.
    if (!isWin || this.checking) return;
    this.checking = true;
    snapshot()
      .then(s => {
        // A failed probe keeps the last answer rather than ending a meeting
        // because PowerShell hiccuped.
        if (s === null || this.timer === null) return;
        this.autoDetected = detectMeeting(s);
        this.recomputeState();
      })
      .catch(() => {})
      .finally(() => { this.checking = false; });
  }
}
