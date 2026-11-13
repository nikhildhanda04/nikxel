import { StateMachine } from "../core/stateMachine";
import { diag } from "../core/diag";
import { GoogleAuth } from "./googleAuth";

/// Polls the primary Google Calendar and nudges the avatar shortly before an
/// event starts.
///
/// All the OAuth plumbing this used to own -- creds, tokens, the loopback
/// listener, refresh -- now lives in GoogleAuth, shared with GoogleSync so both
/// features run off one grant and one token file.
/// Each fetch looks a poll ahead and sets a timer per event, so the alert
/// still lands on time; this used to be a fetch every 30 seconds.
const POLL_MS = 300_000;

export class GoogleCalendarWatcher {
  readonly stateMachine: StateMachine;
  private timer: NodeJS.Timeout | null = null;
  private firedEventIds = new Set<string>();
  private leadMinutes = 2;

  onReminder: ((text: string) => void) | null = null;

  constructor(sm: StateMachine) {
    this.stateMachine = sm;
  }

  start(): void {
    GoogleAuth.shared.onAuthorized = () => this.scheduleTimer();
    GoogleAuth.shared.start();
  }

  stop(): void {
    if (this.timer) clearInterval(this.timer);
    this.timer = null;
    GoogleAuth.shared.stop();
  }

  reauthenticate(): void {
    GoogleAuth.shared.onAuthorized = () => this.scheduleTimer();
    GoogleAuth.shared.reauthenticate();
  }

  setLeadMinutes(m: number): void { this.leadMinutes = Math.max(0, Math.floor(m)); }

  // MARK: - Polling

  private scheduleTimer(): void {
    if (this.timer) clearInterval(this.timer);
    this.timer = setInterval(() => void this.checkUpcoming(), POLL_MS);
    void this.checkUpcoming();
  }

  private async checkUpcoming(): Promise<void> {
    let token: string;
    try { token = await GoogleAuth.shared.getAccessToken(); } catch { return; }
    await this.fetchEvents(token);
  }

  private async fetchEvents(accessToken: string): Promise<void> {
    const now = new Date();
    const windowEnd = new Date(now.getTime() + (this.leadMinutes * 60 + 60) * 1000 + POLL_MS);
    const params = new URLSearchParams({
      timeMin: internetDateTime(now),
      timeMax: internetDateTime(windowEnd),
      singleEvents: "true",
      orderBy: "startTime",
      maxResults: "10",
    });
    let res: Response;
    let obj: any;
    try {
      res = await fetch(`https://www.googleapis.com/calendar/v3/calendars/primary/events?${params}`, {
        headers: { Authorization: `Bearer ${accessToken}` },
      });
      obj = await res.json();
    } catch (e) {
      diag("GoogleCalendar", `fetch failed: ${(e as Error).message}`);
      return;
    }
    // 401 -> force a refresh on the next tick
    if (res.status === 401) {
      GoogleAuth.shared.invalidateAccessToken();
      return;
    }
    const items = obj?.items;
    if (!Array.isArray(items)) return;
    for (const item of items) {
      const id = item?.id;
      if (typeof id !== "string") continue;
      if (this.firedEventIds.has(id)) continue;
      const title: string = typeof item.summary === "string" ? item.summary : "Meeting";
      const start = item.start;
      if (!start || typeof start !== "object") continue;
      const startStr: string = (typeof start.dateTime === "string" ? start.dateTime : null)
        ?? (typeof start.date === "string" ? start.date : null) ?? "";
      const startDate = GoogleCalendarWatcher.parseGCalDate(startStr);
      if (!startDate) continue;
      const secondsUntil = (startDate.getTime() - Date.now()) / 1000;
      if (secondsUntil <= 0) continue;
      this.firedEventIds.add(id);
      const fireIn = Math.max(0, secondsUntil - this.leadMinutes * 60);
      setTimeout(() => {
        // A PC that slept through it doesn't alert late.
        const left = (startDate.getTime() - Date.now()) / 1000;
        if (left <= -60) return;
        const minutesUntil = Math.max(1, Math.floor(left / 60));
        const when = minutesUntil <= 1 ? "starting now" : `in ${minutesUntil} min`;
        this.stateMachine.triggerAlert();
        this.onReminder?.(`📅 ${title} — ${when}`);
      }, fireIn * 1000);
    }
    if (this.firedEventIds.size > 200) this.firedEventIds.clear();
  }

  static parseGCalDate(s: string): Date | null {
    // RFC 3339 with an offset or Z, with or without fractional seconds.
    if (/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:\d{2})$/i.test(s)) {
      const t = Date.parse(s);
      return Number.isNaN(t) ? null : new Date(t);
    }
    // All-day events: "YYYY-MM-DD", local midnight.
    const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(s);
    if (m) return new Date(Number(m[1]), Number(m[2]) - 1, Number(m[3]));
    return null;
  }
}

/// ISO 8601 "internet date time" in UTC without fractional seconds, like
/// ISO8601DateFormatter with .withInternetDateTime.
function internetDateTime(d: Date): string {
  return d.toISOString().replace(/\.\d{3}Z$/, "Z");
}
