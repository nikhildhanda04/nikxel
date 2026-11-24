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
  return micCallSource(key) !== null;
}

/// The call a mic-holding app means, for the "record it?" prompt ("a Zoom call"), or null.
export function micCallSource(key: string): string | null {
  const name = key.includes("#") ? (key.split("#").pop() ?? "").toLowerCase() : key.toLowerCase();
  const packaged = !key.includes("#");
  const is = (exe: RegExp, pkg: RegExp) => (packaged ? pkg.test(name) : exe.test(name));
  if (is(/^zoom\.exe$/, /zoom/)) return "a Zoom call";
  if (is(/^(teams|ms-teams|msteams)\.exe$/, /teams/)) return "a Teams call";
  if (is(/^(webexmta|ciscocollabhost|atmgr)\.exe$/, /webex/)) return "a Webex call";
  if (is(/^whatsapp\.exe$/, /whatsapp/)) return "a WhatsApp call";
  if (is(/^slack\.exe$/, /^$/)) return "a Slack huddle";
  // A browser holding the mic: a web call — Meet, or Zoom/Teams on the web.
  if (is(/^(chrome|msedge|brave|firefox|opera|vivaldi|arc|chromium)\.exe$/, /^$/)) return BROWSER_CALL;
  return null;
}

/// Holding the mic without it being a recording: Nikxel itself (its recorder
/// and chat mic; electron.exe in a dev build), Cortana and voice typing.
const IGNORED_MIC = /^(nikxel|electron)\.exe$|cortana|windows\.client|voiceaccess|texttospeech|speechruntime/i;

/// Any other app holding the mic, by a readable name ("SoundRecorder",
/// "obs64"), or null: one that isn't a call app and isn't Nikxel or Windows
/// speech. Not a meeting -- it doesn't change isInMeeting, so dictation
/// doesn't put the WhatsApp bot in meeting mode -- but Nikxel offers to
/// record it all the same. Mirrors MeetingDetector.micUsers on the Mac.
export function micOtherApp(keys: string[]): string | null {
  for (const key of keys) {
    if (micCallSource(key) !== null) continue;
    const exe = key.includes("#") ? key.split("#").pop() ?? "" : key;
    if (IGNORED_MIC.test(exe)) continue;
    // "Microsoft.WindowsSoundRecorder_8wekyb3d8bbwe" -> "WindowsSoundRecorder"; "C:#…#obs64.exe" -> "obs64".
    const name = key.includes("#") ? exe.replace(/\.exe$/i, "") : (exe.split("_")[0].split(".").pop() ?? exe);
    if (name) return name;
  }
  return null;
}

/// Zoom titles its in-call window "Zoom Meeting" / "Zoom Webinar" — enough on
/// its own, even when the user joined muted with the mic not yet opened.
export function isZoomMeetingWindow(proc: string, title: string): boolean {
  return proc.toLowerCase() === "zoom" && /^Zoom (Meeting|Webinar)\b/.test(title.trim());
}

export function detectMeeting(s: DesktopSnapshot): boolean {
  return meetingSource(s) !== null;
}

/// What the meeting is, for the "record it?" prompt: "Google Meet", "a Zoom call", … or null.
export function meetingSource(s: DesktopSnapshot): string | null {
  const meet = s.windows.some(w => BROWSERS.has(w.proc.toLowerCase()) && isMeetTitle(w.title));
  const mic = s.mic.map(micCallSource).find(src => src !== null) ?? null;
  // A browser holding the mic is named after the Meet window when one is showing.
  if (mic === BROWSER_CALL) return meet ? "Google Meet" : mic;
  if (mic) return mic;
  if (meet) return "Google Meet";
  return s.windows.some(w => isZoomMeetingWindow(w.proc, w.title)) ? "a Zoom call" : null;
}

const BROWSER_CALL = "a call in your browser";

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
  /// What the auto-detection saw, for the "record it?" prompt. null when none.
  source: string | null = null;
  /// Any other app holding the microphone (micOtherApp), and who to tell when it changes.
  micApp: string | null = null;
  onMicAppChanged: ((app: string | null) => void) | null = null;
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
        this.source = meetingSource(s);
        this.autoDetected = this.source !== null;
        this.recomputeState();
        const other = micOtherApp(s.mic);
        if (other !== this.micApp) { this.micApp = other; this.onMicAppChanged?.(other); }
      })
      .catch(() => {})
      .finally(() => { this.checking = false; });
  }
}
