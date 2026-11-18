import { PSHelper, PS_END } from "../system/psHelper";
import { GoogleAuth } from "../google/googleAuth";
import { cblog } from "../core/diag";

/// Port of MeetSpeakers.swift: who is in the Google Meet and who is talking,
/// read from the browser once a second while a meeting records. No extension
/// and no captions: Meet already marks the tile of whoever is speaking, and
/// the tile carries the person's name. Emails come from the calendar invite
/// (`attendees`), since Meet never shows them.
///
/// The Mac reads the page through Accessibility; here it's UI Automation,
/// which Chromium browsers (Chrome, Edge, Brave, Arc) answer with the page's
/// tree. Chromium puts the DOM `class` attribute in UIA's ClassName, so the
/// same class names apply. One PowerShell stays up for the recording and
/// answers each tick, rather than a fresh one every second.
///
/// Turns into the "[Google Meet]" header and per-line names TranscriptMerger
/// puts in the transcript, so the summary names people instead of guessing.

/// Seconds from the recording's start, and who Meet showed talking.
export interface Span { start: number; end: number; name: string }

export interface MeetResult {
  code: string | null;
  names: string[];
  spans: Span[];
}

export class MeetSpeakers {
  static readonly shared = new MeetSpeakers();

  /// Meet's class names are generated and change between Meet releases.
  /// As of Nov 2026: a participant tile, and the class a tile has while that
  /// person is talking. If a whole meeting goes by without either, the log
  /// says so -- that's the sign these need updating.
  static readonly tileClass = "dkjMxf";
  static readonly speakingClass = "kssMZb";

  private helper: PSHelper | null = null;
  private timer: NodeJS.Timeout | null = null;
  private started = 0;
  private result: MeetResult = { code: null, names: [], spans: [] };
  private talking: { name: string; since: number } | null = null;
  private busy = false;

  start(): void {
    if (this.timer) clearInterval(this.timer);
    this.started = Date.now();
    this.result = { code: null, names: [], spans: [] };
    this.talking = null;
    this.helper ??= new PSHelper("meet-speakers", script());
    this.timer = setInterval(() => void this.tick(), 1000);
    void this.tick();
  }

  stop(): MeetResult {
    if (this.timer) clearInterval(this.timer);
    this.timer = null;
    this.helper?.stop();
    this.helper = null;
    this.closeSpan((Date.now() - this.started) / 1000);
    const r = this.result;
    if (r.code !== null) {
      cblog(`MeetSpeakers: ${r.code} — ${r.names.length} joined, ${r.spans.length} speaking turns`);
      if (r.names.length === 0 || r.spans.length === 0) {
        cblog(`MeetSpeakers: no ${r.names.length === 0 ? "tiles" : "speaking highlight"} found; Meet's class names may have changed`);
      }
    }
    return r;
  }

  private async tick(): Promise<void> {
    // A slow answer (first start, a big page) skips ticks rather than queueing them.
    if (this.busy || !this.helper) return;
    this.busy = true;
    const result = this.result;
    const now = (Date.now() - this.started) / 1000;
    const answer = await this.helper.request("tick");
    this.busy = false;
    if (result !== this.result || !answer) return;  // stopped or restarted meanwhile
    let page: { title?: string; names?: string[] | string; speaking?: string };
    try { page = JSON.parse(answer); } catch { return; }
    if (!page.title) return;  // no Meet tab found
    const last = page.title.split(" - ").pop() ?? "";
    result.code = last.includes("-") ? last : null;

    for (const name of ([] as string[]).concat(page.names ?? [])) {
      if (!result.names.includes(name)) result.names.push(name);
    }
    const speaking = page.speaking || null;
    if (speaking !== (this.talking?.name ?? null)) {
      this.closeSpan(now);
      if (speaking) this.talking = { name: speaking, since: now };
    }
  }

  private closeSpan(t: number): void {
    const cur = this.talking;
    if (cur && t > cur.since) this.result.spans.push({ start: cur.since, end: t, name: cur.name });
    this.talking = null;
  }

  // MARK: - Emails

  /// Name → email from the calendar event whose Meet link has `code`.
  /// Gives up after ~10s. Empty without a Google connection.
  static async emails(code: string, around: Date): Promise<Record<string, string>> {
    let token: string;
    try { token = await GoogleAuth.shared.getAccessToken(); } catch { return {}; }
    const params = new URLSearchParams({
      timeMin: new Date(around.getTime() - 12 * 3600_000).toISOString(),
      timeMax: new Date(around.getTime() + 12 * 3600_000).toISOString(),
      singleEvents: "true",
      maxResults: "100",
    });
    let attendees: any[] = [];
    try {
      const res = await fetch(`https://www.googleapis.com/calendar/v3/calendars/primary/events?${params}`, {
        headers: { Authorization: `Bearer ${token}` },
        signal: AbortSignal.timeout(10_000),
      });
      const items: any[] = ((await res.json()) as any)?.items ?? [];
      const event = items.find(e => typeof e?.hangoutLink === "string" && e.hangoutLink.endsWith(code));
      attendees = Array.isArray(event?.attendees) ? event.attendees : [];
    } catch { return {}; }
    const out: Record<string, string> = {};
    for (const a of attendees) {
      if (typeof a?.email !== "string") continue;
      out[typeof a.displayName === "string" ? a.displayName : a.email] = a.email;
    }
    return out;
  }

  /// The email for a name Meet showed: the invite's display name, or an
  /// address whose local part has their first name ("prince@…" for Prince Choudhary).
  static email(name: string, emails: Record<string, string>): string | null {
    const key = Object.keys(emails).find(k => k.toLowerCase() === name.toLowerCase());
    if (key !== undefined) return emails[key];
    const first = (name.trim().split(/\s+/)[0] ?? "").toLowerCase();
    if (first.length < 3) return null;
    const hits = Object.values(emails).filter(e => e.toLowerCase().split("@")[0].includes(first));
    return hits.length === 1 ? hits[0] : null;
  }
}

/// Each "tick" answers one JSON line: the Meet tab's title (empty when there
/// is none), every tile's name, and the speaking tile's name. The tab is
/// looked for only in Chromium windows whose title says Meet -- the active
/// tab's -- and, once found, kept and read even after another tab or window
/// comes to the front, until it stops being a Meet page.
///
/// One FindAll with a cache request pulls the whole page's class names, names
/// and control types in a single cross-process call; walking it element by
/// element would be thousands of calls a second. FindAll is in document
/// order, so a tile's name is the first text after it.
function script(): string {
  return String.raw`
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
$AE = [System.Windows.Automation.AutomationElement]
$Scope = [System.Windows.Automation.TreeScope]
$TextType = [System.Windows.Automation.ControlType]::Text
$any = [System.Windows.Automation.Condition]::TrueCondition
$docCond = New-Object System.Windows.Automation.PropertyCondition($AE::ControlTypeProperty, [System.Windows.Automation.ControlType]::Document)
$cr = New-Object System.Windows.Automation.CacheRequest
$cr.Add($AE::ClassNameProperty); $cr.Add($AE::NameProperty); $cr.Add($AE::ControlTypeProperty)
$web = $null
function Find-Meet {
  foreach ($w in $AE::RootElement.FindAll($Scope::Children, $any)) {
    if ($w.Current.ClassName -ne 'Chrome_WidgetWin_1' -or $w.Current.Name -notlike '*Meet - *') { continue }
    foreach ($d in $w.FindAll($Scope::Descendants, $docCond)) {
      if ($d.Current.Name -like 'Meet - *') { return $d }
    }
  }
  return $null
}
while ($null -ne ($line = [Console]::In.ReadLine())) {
  try {
    if ($web) { try { if ($web.Current.Name -notlike 'Meet - *') { $web = $null } } catch { $web = $null } }
    if (-not $web) { $web = Find-Meet }
    $title = ''; $names = @(); $speaking = ''
    if ($web) {
      $title = [string]$web.Current.Name
      $act = $cr.Activate()
      try { $all = $web.FindAll($Scope::Descendants, $any) } finally { $act.Dispose() }
      $tile = $null
      foreach ($e in $all) {
        $cls = ' ' + [string]$e.Cached.ClassName + ' '
        if ($cls.Contains(' ${MeetSpeakers.tileClass} ')) { $tile = $cls; continue }
        if ($tile -and $e.Cached.ControlType -eq $TextType) {
          $n = ([string]$e.Cached.Name).Trim()
          if (-not $n) { continue }
          $names += $n
          if (-not $speaking -and $tile.Contains(' ${MeetSpeakers.speakingClass} ')) { $speaking = $n }
          $tile = $null
        }
      }
    }
    $json = (@{ title = $title; names = $names; speaking = $speaking } | ConvertTo-Json -Compress)
    # \uXXXX for anything non-ASCII, as desktopHelper's "fg" does.
    $json = [regex]::Replace($json, '[^\x00-\x7F]', [Text.RegularExpressions.MatchEvaluator]{ param($m) '\u{0:x4}' -f [int][char]$m.Value })
    [Console]::Out.WriteLine($json)
  } catch { $web = $null }
  [Console]::Out.WriteLine('${PS_END}')
  [Console]::Out.Flush()
}
`;
}
