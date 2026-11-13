import { PSHelper, PS_END } from "./psHelper";
import { AgentMonitor } from "./agentMonitor";

/// One PowerShell for every Windows probe: the agent monitor ("agent"), the
/// day logger's foreground window ("fg") and the meeting detector ("meet").
/// Each powershell.exe holds 40-80 MB, and there used to be three of them,
/// each compiling its own Win32 shim. Requests are serialised, which is fine:
/// the slowest answers in well under a second and they're seconds apart.
let helper: PSHelper | null = null;

export function desktopRequest(kind: "agent" | "fg" | "meet", timeoutMs: number): Promise<string | null> {
  if (!helper) helper = new PSHelper("desktop", script());
  return helper.request(kind, timeoutMs);
}

export function stopDesktopHelper(): void {
  helper?.stop();
  helper = null;
}

/// Win32 shims for "meet" (every visible window's title and pid) and "fg"
/// (the foreground window and its exe), compiled once.
const WIN32 = String.raw`
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
public static class NxFg {
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern int GetWindowTextLengthW(IntPtr h);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("kernel32.dll", SetLastError = true)] public static extern IntPtr OpenProcess(uint access, bool inherit, uint pid);
  [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] public static extern bool QueryFullProcessImageNameW(IntPtr h, uint flags, StringBuilder s, ref uint n);
  [DllImport("kernel32.dll")] public static extern bool CloseHandle(IntPtr h);
  public static string Title(IntPtr h) {
    int len = GetWindowTextLengthW(h);
    if (len <= 0) return "";
    var sb = new StringBuilder(len + 1);
    GetWindowTextW(h, sb, sb.Capacity);
    return sb.ToString();
  }
  public static string ImagePath(uint pid) {
    IntPtr hp = OpenProcess(0x1000, false, pid);
    if (hp == IntPtr.Zero) return "";
    try {
      var sb = new StringBuilder(1024);
      uint n = (uint)sb.Capacity;
      return QueryFullProcessImageNameW(hp, 0, sb, ref n) ? sb.ToString() : "";
    } finally { CloseHandle(hp); }
  }
}
`;

/// "meet": the microphone's current users, and a pid -> process name cache
/// so only windows' owners are looked up, not every process each poll.
const MEET_SETUP = String.raw`
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
$pn = @{}
`;

const MEET_BODY = String.raw`
$wins = @()
foreach ($w in [NxMeetWin]::Titles()) {
    $parts = $w.Split([char]9, 2)
    $id = [int]$parts[0]
    if (-not $pn.ContainsKey($id)) {
        if ($pn.Count -gt 500) { $pn.Clear() }
        try { $pn[$id] = [Diagnostics.Process]::GetProcessById($id).ProcessName } catch { $pn[$id] = '' }
    }
    $wins += @{ proc = [string]$pn[$id]; title = [string]$parts[1] }
}
$res = @{ windows = $wins; mic = (Get-MicInUse) }
[Console]::Out.WriteLine(($res | ConvertTo-Json -Compress -Depth 4))
`;

export function script(): string {
  /// "agent": one line per candidate process -- see AgentMonitor.
  const agentSetup = `
$cmdCache = @{}
$agentNames = @('node', 'bun', ${AgentMonitor.agentNames.map(n => `'*${n}*'`).join(", ")})
`;
  const agentBody = `
    $procs = @(Get-Process -Name $agentNames -ErrorAction SilentlyContinue)
    $live = @{}
    foreach ($p in $procs) {
      $id = $p.Id
      $live[$id] = $true
      $cpu = 0.0
      if ($null -ne $p.CPU) { $cpu = [double]$p.CPU }
      $cmd = ''
      if ($p.ProcessName -eq 'node' -or $p.ProcessName -eq 'bun') {
        if ($cmdCache.ContainsKey($id)) { $cmd = $cmdCache[$id] }
        else {
          $ci = Get-CimInstance Win32_Process -Filter "ProcessId=$id" -Property CommandLine -ErrorAction SilentlyContinue
          if ($ci -and $ci.CommandLine) { $cmd = ($ci.CommandLine -replace "[\`t\`r\`n]", ' ') }
          $cmdCache[$id] = $cmd
        }
      }
      [Console]::Out.WriteLine(("{0}\`t{1}\`t{2}\`t{3}" -f $id, $cpu.ToString([Globalization.CultureInfo]::InvariantCulture), $p.ProcessName, $cmd))
    }
    foreach ($k in @($cmdCache.Keys)) { if (-not $live.ContainsKey($k)) { $cmdCache.Remove($k) } }
`;
  /// "fg": the foreground window's app and title as one JSON line -- see DayLogger.
  const fgSetup = `
$fgNames = @{}
`;
  const fgBody = `
  $app = ''; $title = ''
  try {
    $h = [NxFg]::GetForegroundWindow()
    if ($h -ne [IntPtr]::Zero) {
      $title = [NxFg]::Title($h)
      $fpid = [uint32]0
      [void][NxFg]::GetWindowThreadProcessId($h, [ref]$fpid)
      $exe = [NxFg]::ImagePath($fpid)
      if ($exe) {
        if ($fgNames.ContainsKey($exe)) { $app = $fgNames[$exe] }
        else {
          $desc = ''
          try { $desc = [Diagnostics.FileVersionInfo]::GetVersionInfo($exe).FileDescription } catch { }
          if ($desc) { $desc = $desc.Trim() }
          if (-not $desc) { $desc = [IO.Path]::GetFileNameWithoutExtension($exe) }
          $fgNames[$exe] = $desc
          $app = $desc
        }
        if ([IO.Path]::GetFileName($exe) -ieq 'ApplicationFrameHost.exe' -and $title) { $app = $title }
      }
    }
  } catch { }
  $json = (@{ app = [string]$app; title = [string]$title } | ConvertTo-Json -Compress)
  # \\uXXXX for anything non-ASCII, so a title survives even if the console
  # encoding couldn't be switched to UTF-8.
  $json = [regex]::Replace($json, '[^\\x00-\\x7F]', [Text.RegularExpressions.MatchEvaluator]{ param($m) '\\u{0:x4}' -f [int][char]$m.Value })
  [Console]::Out.WriteLine($json)
`;
  return "Add-Type -TypeDefinition @'" + WIN32 + "'@\n" + MEET_SETUP + agentSetup + fgSetup + `
while ($null -ne ($line = [Console]::In.ReadLine())) {
  try {
    switch ($line) {
      'agent' {${agentBody}}
      'fg' {${fgBody}}
      'meet' {${MEET_BODY}}
    }
  } catch { }
  [Console]::Out.WriteLine('${PS_END}')
  [Console]::Out.Flush()
}
`;
}
