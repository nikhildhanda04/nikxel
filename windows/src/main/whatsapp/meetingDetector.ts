import type { ChildProcess } from "child_process";
import { isWin } from "../core/paths";
import { spawnProcess, killTree } from "../core/proc";
import { bus } from "../core/bus";
import { cblog, diag } from "../core/diag";

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

/// Long-lived PowerShell that answers each "check" line with one JSON line,
/// so an 8 s poll doesn't start (and compile the Win32 shim in) a new
/// PowerShell every tick.
const HELPER_SCRIPT = String.raw`
$ErrorActionPreference = 'SilentlyContinue'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false
Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public static class NxMeetWin {
    private delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] private static extern bool EnumWindows(EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] private static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetWindowTextW(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] private static extern int GetWindowTextLengthW(IntPtr h);
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    public static List<string> Titles() {
        var list = new List<string>();
        EnumProc cb = delegate(IntPtr h, IntPtr l) {
            if (!IsWindowVisible(h)) return true;
            int n = GetWindowTextLengthW(h);
            if (n == 0) return true;
            var sb = new StringBuilder(n + 1);
            GetWindowTextW(h, sb, sb.Capacity);
            uint pid;
            GetWindowThreadProcessId(h, out pid);
            list.Add(pid.ToString() + "\t" + sb.ToString());
            return true;
        };
        EnumWindows(cb, IntPtr.Zero);
        GC.KeepAlive(cb);
        return list;
    }
}
'@
$mic = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\microphone'
function Get-MicInUse {
    $out = @()
    foreach ($root in @($mic, "$mic\NonPackaged")) {
        foreach ($k in @(Get-ChildItem -LiteralPath $root)) {
            $p = Get-ItemProperty -LiteralPath $k.PSPath
            if ($p.LastUsedTimeStart -and $p.LastUsedTimeStop -eq 0) { $out += [string]$k.PSChildName }
        }
    }
    return ,$out
}
while ($true) {
    $line = [Console]::In.ReadLine()
    if ($line -eq $null) { break }
    $procs = @{}
    foreach ($p in @(Get-Process)) { $procs[[int]$p.Id] = $p.ProcessName }
    $wins = @()
    foreach ($w in [NxMeetWin]::Titles()) {
        $parts = $w.Split([char]9, 2)
        $wins += @{ proc = [string]$procs[[int]$parts[0]]; title = [string]$parts[1] }
    }
    $res = @{ windows = $wins; mic = (Get-MicInUse) }
    [Console]::Out.WriteLine(($res | ConvertTo-Json -Compress -Depth 4))
    [Console]::Out.Flush()
}
`;

class DesktopProbe {
  private child: ChildProcess | null = null;
  private buffer = "";
  private waiting: ((line: string | null) => void) | null = null;
  private loggedFailure = false;

  private ensure(): ChildProcess | null {
    if (this.child && this.child.exitCode === null && !this.child.killed) return this.child;
    const encoded = Buffer.from(HELPER_SCRIPT, "utf16le").toString("base64");
    let child: ChildProcess;
    try {
      child = spawnProcess("powershell.exe",
        ["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-EncodedCommand", encoded],
        { stdio: ["pipe", "pipe", "ignore"] });
    } catch (e) {
      this.logOnce(`couldn't start PowerShell (${e})`);
      return null;
    }
    this.buffer = "";
    child.stdout?.setEncoding("utf8");
    child.stdout?.on("data", (d: string) => {
      this.buffer += d;
      let nl: number;
      while ((nl = this.buffer.indexOf("\n")) >= 0) {
        const line = this.buffer.slice(0, nl).trim();
        this.buffer = this.buffer.slice(nl + 1);
        if (!line) continue;
        const w = this.waiting; this.waiting = null;
        w?.(line);
      }
    });
    child.on("error", e => this.logOnce(`PowerShell helper error (${e})`));
    child.on("exit", () => {
      if (this.child === child) this.child = null;
      const w = this.waiting; this.waiting = null;
      w?.(null);
    });
    child.stdin?.on("error", () => { /* helper exited */ });
    this.child = child;
    return child;
  }

  private logOnce(msg: string): void {
    if (this.loggedFailure) return;
    this.loggedFailure = true;
    diag("MeetingDetector", msg);
  }

  /// One snapshot, or null when the helper can't answer. The first call waits
  /// for PowerShell to start and compile its Win32 shim, so it gets longer.
  async snapshot(): Promise<DesktopSnapshot | null> {
    if (this.waiting) return null;   // previous check still running
    const child = this.ensure();
    if (!child?.stdin) return null;
    const line = await new Promise<string | null>(resolve => {
      const timer = setTimeout(() => {
        if (this.waiting === done) this.waiting = null;
        this.logOnce("PowerShell helper timed out — restarting it");
        killTree(child);
        resolve(null);
      }, 20_000);
      const done = (l: string | null) => { clearTimeout(timer); resolve(l); };
      this.waiting = done;
      child.stdin!.write("check\n");
    });
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

  stop(): void {
    if (this.child) { this.child.stdin?.end(); killTree(this.child); }
    this.child = null;
  }
}

export class MeetingDetector {
  static readonly shared = new MeetingDetector();

  private timer: NodeJS.Timeout | null = null;
  private autoDetected = false;
  private _manualOverride = false;
  private _isInMeeting = false;
  private checking = false;
  private probe = new DesktopProbe();

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
    this.probe.stop();
    this.autoDetected = false;
    this._manualOverride = false;
    this.setInMeeting(false);
  }

  private check(): void {
    // Detection reads Win32 windows and the Windows registry; elsewhere (a
    // dev build on a Mac) only the manual override applies.
    if (!isWin || this.checking) return;
    this.checking = true;
    this.probe.snapshot()
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
