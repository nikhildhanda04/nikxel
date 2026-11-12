import * as fs from "fs";
import { nikxelPath, writeAtomic } from "../core/paths";
import { bus } from "../core/bus";
import { diag } from "../core/diag";
import { ui } from "../core/ui";
import { GoogleAuth } from "./googleAuth";

/// Surfaces incomplete Google Tasks the user hasn't seen yet on this PC.
///
/// The Mac app watches Apple Reminders through EventKit. Windows has no such
/// store, so this watches the closest thing a Windows user jots into from
/// their phone: Google Tasks (the default "My Tasks" list -- where the phone
/// app, Gmail and Calendar's side panel add by default). Same behaviour:
///
/// The use case: user is away from the PC, jots a task on their phone. When
/// they next open the PC, those new tasks should bubble up. So we don't filter
/// to "due today" -- we track which task IDs Nikxel has ever shown, persist
/// that across launches (~/.nikxel/google_tasks_seen.json), and only bubble
/// unseen ones.
///
/// On first ever run we bootstrap: mark everything currently incomplete as
/// seen WITHOUT bubbling, so the user isn't bombarded with years of backlog.
/// From that point on, anything new shows up the next time we fetch.
///
/// Tasks Nikxel files itself (a meeting's action items, tasks from chats) go
/// into the same list. GoogleSync records each one's id here as it's created
/// (`rememberOwnTask`), and the notes GoogleSync writes are recognised too, in
/// case a fetch lands between the create and its response.

const TASKS_SCOPE = "https://www.googleapis.com/auth/tasks";
const LIST_URL = "https://tasks.googleapis.com/tasks/v1/lists/@default/tasks";

// MARK: - Seen set (module-level: GoogleSync adds to it too)

const SEEN_FILE = nikxelPath("google_tasks_seen.json");
let seenIDs: Set<string> | null = null;
let bootstrapped = false;
/// Ids GoogleSync created in the last few minutes. Kept through pruning even
/// when a fetch that started before the create doesn't list them yet.
const recentOwn = new Map<string, number>();
const RECENT_OWN_MS = 10 * 60_000;

function seen(): Set<string> {
  if (seenIDs) return seenIDs;
  seenIDs = new Set();
  try {
    const obj = JSON.parse(fs.readFileSync(SEEN_FILE, "utf8"));
    if (Array.isArray(obj?.ids)) for (const id of obj.ids) if (typeof id === "string") seenIDs.add(id);
    bootstrapped = obj?.bootstrapped === true;
  } catch { /* first run */ }
  return seenIDs;
}

function persistSeen(): void {
  try {
    writeAtomic(SEEN_FILE, JSON.stringify({ bootstrapped, ids: [...seen()] }, null, 2));
  } catch (e) { diag("ReminderWatcher", `saving seen set failed: ${e}`); }
}

/// Called by GoogleSync for every task it creates, so Nikxel's own tasks
/// never bubble back as "new reminders".
export function rememberOwnTask(id: string): void {
  seen().add(id);
  recentOwn.set(id, Date.now());
  persistSeen();
}

/// The notes GoogleSync writes: "From <note>.md" (optionally after an
/// "Owner: …" line) and "From a WhatsApp message from <contact>."
const OWN_NOTES = /^(Owner: [^\n]*\n)?From (a WhatsApp message from [^\n]*\.|[^\n]*\.md)$/;

interface GTask { id: string; title: string; notes: string }

export class ReminderWatcher {
  onReminder: ((r: { id: string; title: string }) => void) | null = null;

  private timer: NodeJS.Timeout | null = null;
  private running = false;
  private fetching = false;
  private didShowDeniedAlert = false;

  /// EventKit is local and free to poll every minute; this is a network API
  /// on a quota shared by everyone using the bundled client. Wake refetches
  /// cover the "back at the PC" moment, so the poll can be slower.
  private readonly pollInterval = 5 * 60_000;

  private readonly wakeHandler = () => {
    if (!this.running || !this.timer) return;
    // On wake the network may not be back yet. Refetch immediately AND a bit
    // later so we catch new tasks either way.
    void this.fetchUnseen();
    setTimeout(() => void this.fetchUnseen(), 5000);
  };

  private readonly authorizedHandler = () => {
    if (!this.running) return;
    // A declined Tasks box is already reported by GoogleAuth's own bubble.
    if (GoogleAuth.shared.hasScope(TASKS_SCOPE)) this.beginPolling();
  };

  // MARK: - Lifecycle

  start(): void {
    this.attach();
    // Google is optional: no account, no nagging. Polling starts the moment
    // one is connected (authorizedHandler).
    if (!GoogleAuth.shared.isAuthorized) return;
    if (GoogleAuth.shared.hasScope(TASKS_SCOPE)) this.beginPolling();
    else this.showDeniedAlertIfNeeded();
  }

  private attach(): void {
    this.running = true;
    GoogleAuth.shared.addAuthorizedListener(this.authorizedHandler);
    bus.off("wake", this.wakeHandler);
    bus.on("wake", this.wakeHandler);
  }

  stop(): void {
    this.running = false;
    if (this.timer) clearInterval(this.timer);
    this.timer = null;
    bus.off("wake", this.wakeHandler);
    GoogleAuth.shared.removeAuthorizedListener(this.authorizedHandler);
  }

  /// "Connect Google Tasks…": runs Google's consent again if the grant is
  /// missing (or there is no account yet); otherwise just resumes polling.
  reauthenticate(): void {
    this.didShowDeniedAlert = false;
    this.attach();
    if (GoogleAuth.shared.isAuthorized && GoogleAuth.shared.hasScope(TASKS_SCOPE)) {
      this.beginPolling();
    } else {
      GoogleAuth.shared.reauthenticate();
    }
  }

  // MARK: - Access

  private showDeniedAlertIfNeeded(): void {
    if (this.didShowDeniedAlert) return;
    this.didShowDeniedAlert = true;
    this.showAccessAlert();
  }

  private showAccessAlert(): void {
    ui.ask({
      icon: "📝", title: "Google Tasks access not granted",
      lines: ["Nikxel shows tasks you added on other devices. Reconnect Google and leave the Tasks box ticked."],
      kind: "warning",
      buttons: [
        { title: "Reconnect", action: () => GoogleAuth.shared.reauthenticate() },
        { title: "Later", action: () => {} },
      ],
    });
  }

  // MARK: - Polling

  private beginPolling(): void {
    if (this.timer) clearInterval(this.timer);
    this.timer = setInterval(() => void this.fetchUnseen(), this.pollInterval);
    void this.fetchUnseen();
  }

  /// Every incomplete task in the default list, or null on any failure -- a
  /// partial list would prune the seen set and re-bubble the rest later.
  private async fetchIncomplete(): Promise<GTask[] | null> {
    let token: string;
    try { token = await GoogleAuth.shared.getAccessToken(); } catch { return null; }
    const out: GTask[] = [];
    let pageToken: string | null = null;
    for (let page = 0; page < 50; page++) {
      const params = new URLSearchParams({ showCompleted: "false", showHidden: "false", maxResults: "100" });
      if (pageToken) params.set("pageToken", pageToken);
      let res: Response;
      let obj: any;
      try {
        res = await fetch(`${LIST_URL}?${params}`, { headers: { Authorization: `Bearer ${token}` } });
        obj = await res.json().catch(() => null);
      } catch (e) {
        diag("ReminderWatcher", `fetch failed: ${(e as Error).message}`);
        return null;
      }
      if (res.status === 401) { GoogleAuth.shared.invalidateAccessToken(); return null; }
      if (res.status === 403) {
        const msg: string = obj?.error?.message ?? "HTTP 403";
        diag("ReminderWatcher", `fetch refused: ${msg}`);
        // Narrowed grant: say so once, like the Mac's "access not granted".
        if (/insufficient|scope/i.test(msg)) this.showDeniedAlertIfNeeded();
        return null;
      }
      if (!res.ok) { diag("ReminderWatcher", `fetch failed: HTTP ${res.status}`); return null; }
      for (const t of Array.isArray(obj?.items) ? obj.items : []) {
        if (typeof t?.id !== "string" || t.status === "completed" || t.deleted) continue;
        out.push({
          id: t.id,
          title: typeof t.title === "string" ? t.title : "",
          notes: typeof t.notes === "string" ? t.notes : "",
        });
      }
      pageToken = typeof obj?.nextPageToken === "string" ? obj.nextPageToken : null;
      if (!pageToken) break;
    }
    return out;
  }

  private async fetchUnseen(): Promise<void> {
    if (this.fetching) return;
    this.fetching = true;
    try {
      const tasks = await this.fetchIncomplete();
      if (tasks && this.running) this.processFetched(tasks);
    } finally {
      this.fetching = false;
    }
  }

  private processFetched(tasks: GTask[]): void {
    const seenSet = seen();
    const currentIDs = new Set(tasks.map(t => t.id));

    // First ever run: silently mark every existing incomplete task as seen
    // so we don't dump the whole backlog on the user.
    if (!bootstrapped) {
      for (const id of currentIDs) seenSet.add(id);
      bootstrapped = true;
      persistSeen();
      return;
    }

    // Prune IDs we used to know about but that are no longer in the
    // incomplete set (completed or deleted). Keeps the persisted set bounded
    // over years of use. Nikxel's own just-created ids survive one round, in
    // case this fetch began before Google had them.
    const now = Date.now();
    for (const [id, at] of recentOwn) if (now - at > RECENT_OWN_MS) recentOwn.delete(id);
    for (const id of [...seenSet]) {
      if (!currentIDs.has(id) && !recentOwn.has(id)) seenSet.delete(id);
    }

    for (const t of tasks) {
      if (seenSet.has(t.id)) continue;
      const title = t.title.trim();
      // Google Tasks makes a blank task the moment you start a new row; let
      // it bubble once it has a title rather than as "Reminder".
      if (!title) continue;
      seenSet.add(t.id);
      if (OWN_NOTES.test(t.notes)) continue;
      this.onReminder?.({ id: t.id, title });
    }
    persistSeen();
  }

  // MARK: - Complete

  /// Mark the task with the given id as completed.
  complete(id: string): void {
    void (async () => {
      let token: string;
      try { token = await GoogleAuth.shared.getAccessToken(); } catch (e) {
        diag("ReminderWatcher", `failed to mark complete: ${(e as Error).message}`);
        return;
      }
      try {
        const res = await fetch(`${LIST_URL}/${encodeURIComponent(id)}`, {
          method: "PATCH",
          headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
          body: JSON.stringify({ status: "completed" }),
        });
        if (res.status === 401) GoogleAuth.shared.invalidateAccessToken();
        if (!res.ok) diag("ReminderWatcher", `failed to mark complete: HTTP ${res.status} ${await res.text().catch(() => "")}`);
      } catch (e) {
        diag("ReminderWatcher", `failed to mark complete: ${(e as Error).message}`);
      }
    })();
  }
}
