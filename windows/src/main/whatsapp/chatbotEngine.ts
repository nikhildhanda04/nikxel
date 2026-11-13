import type { MOMGenerator } from "../recording/momGenerator";
import { GoogleSync } from "../google/googleSync";
import { Settings } from "../core/settings";
import { bus } from "../core/bus";
import { cblog } from "../core/diag";
import { ChromeWhatsApp, type WAUnreadChat } from "./chromeWhatsApp";
import { LLMResponder } from "./llmResponder";
import { MeetingDetector } from "./meetingDetector";
import { WAContactLists } from "./waContactLists";
import { WABotGate, containsMeetingLink, fingerprint, runsOutsideMeetings } from "./waBotGate";

export { WABotGate } from "./waBotGate";

export interface Delivered {
  contact: string;
  text: string;
  /// Task filed to Google Tasks off the back of this message, if any.
  task: string | null;
}

/// Messages seen but not yet answered, keyed the same way as `baselineCounts`.
/// An entry lives from the moment new unread arrives until either the bot
/// replies or the user reads the chat themselves.
interface Pending {
  chat: WAUnreadChat;
  newCount: number;
  since: Date;
  /// Polls this chat was opened but its newest message hadn't rendered.
  staleReads: number;
}

/// Calls agreed in chat, keyed like `pending`: the Meet link goes to the
/// contact at `at`.
/// ponytail: in memory only -- a call scheduled before a restart loses its
/// share (the calendar event survives). Persist to disk if that bites.
interface ScheduledMeet {
  contact: string;
  at: Date;
  link: string | null;
  eventId: string | null;
  /// Kept an hour after the link goes out, so "give me 5 more minutes"
  /// is understood as running late, not as a new call needing a new link.
  sentAt: Date | null;
}

const sleep = (ms: number) => new Promise<void>(r => setTimeout(r, ms));
const keyOf = (name: string) => name.toLowerCase().trim();

/// GoogleSync.createChatMeet's Swift completion was `(link, eventId)`. As a
/// Promise it may resolve to `{ link, eventId }`, a `[link, eventId]` pair or
/// a bare link; read any of them.
function meetResult(r: unknown): { link: string | null; eventId: string | null } {
  const str = (v: unknown) => (typeof v === "string" && v ? v : null);
  if (Array.isArray(r)) return { link: str(r[0]), eventId: str(r[1]) };
  if (r && typeof r === "object") {
    const o = r as Record<string, unknown>;
    return { link: str(o.link), eventId: str(o.eventId ?? o.id) };
  }
  return { link: str(r), eventId: null };
}

/// Fire-and-forget a GoogleSync call that may return a Promise or nothing.
function background(what: string, call: () => unknown): void {
  try {
    Promise.resolve(call()).catch(e => cblog(`ChatbotEngine: ${what} failed — ${e}`));
  } catch (e) {
    cblog(`ChatbotEngine: ${what} failed — ${e}`);
  }
}

export class ChatbotEngine {
  static readonly shared = new ChatbotEngine();

  /// Pure helpers, under their Swift names.
  static readonly fingerprint = fingerprint;
  static readonly containsMeetingLink = containsMeetingLink;

  private timer: NodeJS.Timeout | null = null;
  private llm: LLMResponder | null = null;
  /// Fast while a meeting is on (a stand-in reply is only useful if it is
  /// prompt); slow the rest of the day, where the bot is either waiting out
  /// an unattended timer measured in minutes or just idling.
  private readonly meetingPollInterval = 5;
  private readonly idlePollInterval = 20;
  /// "Reply immediately" promises an answer inside a minute; a 20s poll plus
  /// the agent run ate half of that before the reply was even written.
  private readonly alwaysPollInterval = 10;
  private currentInterval = 0;
  // Short cooldown only — the baseline-delta logic in performCheck already
  // prevents replying to the same message twice, so the cooldown only has
  // to throttle pathological bursts (e.g. WhatsApp reordering the sidebar
  // and re-detecting the same chat within one poll cycle).
  private readonly replyCooldown = 10;

  // Baseline: contact → unread count at meeting start.
  private baselineCounts = new Map<string, number>();
  // Cooldown: contact → last reply time.
  private lastReplyTime = new Map<string, Date>();
  // What the bot has sent, per contact, so the chat thread can tell the
  // bot's bubbles from the user's own. Capped; only recent ones matter.
  private sentByBot = new Map<string, string[]>();
  private readonly sentCap = 12;

  private pending = new Map<string, Pending>();

  private meets = new Map<string, ScheduledMeet>();
  /// Runs while any call is scheduled, independent of the reply poller, so a
  /// link still goes out after a meeting ends in meetings-only mode.
  private meetTimer: NodeJS.Timeout | null = null;

  /// Fired after a batch of replies, with one entry per contact answered and
  /// whether they were drafted rather than sent. Wired to the avatar card in
  /// main.ts.
  onRepliesSent: ((batch: Delivered[], drafted: boolean) => void) | null = null;

  private _activeContactName: string | null = null;
  get activeContactName(): string | null { return this._activeContactName; }
  private cancelled = false;
  private pollingInProgress = false;
  private lastUnreadLogged = -1;
  /// Set while the activity logger has the page on the Calls tab or mid
  /// -reload. The chat list reads as empty then, and an empty list clears
  /// `pending` and the baseline -- so polls skip instead.
  private held = false;

  get hasPending(): boolean { return this.pending.size > 0; }

  /// Run `work` with polling held off, once any poll in flight has finished.
  /// `work` resolving false means the page didn't come back cleanly:
  /// re-baseline so old unread isn't taken as new.
  async withPollingHeld(work: () => Promise<boolean>): Promise<void> {
    this.held = true;
    try {
      const deadline = Date.now() + 60_000;
      while (this.pollingInProgress && Date.now() < deadline) await new Promise(r => setTimeout(r, 200));
      if (!(await work())) this.baselineReady = false;
    } finally {
      this.held = false;
    }
  }
  private baselineReady = false;

  private readonly onMeetingStateChanged = () => this.meetingStateChanged();

  // User toggle (persisted). When false, the bot never auto-replies, even in a meeting.
  get isEnabled(): boolean { return Settings.botEnabled; }
  set isEnabled(v: boolean) {
    Settings.botEnabled = v;
    if (v) {
      if (this.shouldRun) { this.cancelled = false; this.startPolling(); }
    } else {
      this.cancelled = true;
      this.stopPolling();
      this.setActiveContact(null);   // clears the "X is texting" bubble immediately
    }
  }

  /// Whether the poller has any reason to be running: the user has the bot
  /// on, and either a meeting is live or the chosen mode covers the rest of
  /// the day too.
  private get shouldRun(): boolean {
    return this.isEnabled && (MeetingDetector.shared.isInMeeting || runsOutsideMeetings(Settings.waBotMode));
  }

  /// Called when the mode or group setting changes from the menu, so the
  /// poller starts, stops or re-paces without waiting for a meeting edge.
  applyModeChange(): void {
    if (this.shouldRun) {
      this.cancelled = false;
      this.startPolling();
    } else {
      this.cancelled = true;
      this.stopPolling();
      this.setActiveContact(null);
    }
  }

  // MARK: - Lifecycle

  start(momGen: MOMGenerator): void {
    this.llm = new LLMResponder(momGen);
    this.reset();
    bus.off("meetingStateChanged", this.onMeetingStateChanged);
    bus.on("meetingStateChanged", this.onMeetingStateChanged);
    cblog(`ChatbotEngine: started (WhatsApp window mode, mode=${Settings.waBotMode})`);
    this.cancelled = false;
    if (this.shouldRun) this.startPolling();
  }

  stop(): void {
    if (this.timer) clearInterval(this.timer);
    this.timer = null;
    this.currentInterval = 0;
    bus.off("meetingStateChanged", this.onMeetingStateChanged);
    this.reset();
  }

  private reset(): void {
    this.cancelled = true; this.pollingInProgress = false; this.baselineReady = false;
    this.baselineCounts.clear(); this.lastReplyTime.clear();
    this.sentByBot.clear(); this.pending.clear(); this.setActiveContact(null);
  }

  private meetingStateChanged(): void {
    const on = MeetingDetector.shared.isInMeeting;
    const allDay = runsOutsideMeetings(Settings.waBotMode);
    cblog(`ChatbotEngine: meeting ${on ? "STARTED" : "ENDED"} (allDay=${allDay})`);
    if (on) {
      // Meeting-only mode treats each meeting as a fresh session; an
      // all-day mode has been running and keeps its baseline, otherwise
      // every meeting would re-ignore whatever was already unread.
      if (!allDay) {
        this.baselineReady = false;
        this.baselineCounts.clear(); this.lastReplyTime.clear();
        this.sentByBot.clear(); this.pending.clear();
      }
      this.cancelled = false;
      this.startPolling();
    } else if (allDay) {
      this.startPolling();   // re-paces to the idle interval
    } else {
      this.cancelled = true; this.stopPolling(); this.reset();
    }
  }

  // MARK: - Polling

  private startPolling(): void {
    if (!this.isEnabled) return;
    const want = MeetingDetector.shared.isInMeeting ? this.meetingPollInterval
      : Settings.waBotMode === "always" ? this.alwaysPollInterval : this.idlePollInterval;
    if (this.timer && this.currentInterval === want) return;
    if (this.timer) clearInterval(this.timer);
    this.currentInterval = want;
    cblog(`ChatbotEngine: polling every ${want}s`);
    this.timer = setInterval(() => this.checkAndReply(), want * 1000);
    this.checkAndReply();
  }

  private stopPolling(): void {
    if (this.timer) clearInterval(this.timer);
    this.timer = null;
    this.currentInterval = 0;
  }

  private checkAndReply(): void {
    if (this.cancelled || this.pollingInProgress || this.held) return;
    this.pollingInProgress = true;
    this.performCheck()
      .catch(e => cblog(`ChatbotEngine: poll failed — ${e instanceof Error ? e.stack ?? e.message : e}`))
      .finally(() => { this.pollingInProgress = false; });
  }

  // MARK: - Core logic

  private async performCheck(): Promise<void> {
    await this.sendDueMeets();
    // 1. Get all unread chats via the page's DOM (fast — one evaluate).
    const unreadChats = await ChromeWhatsApp.unreadChats();
    // Only when it moves: every 10-20s all day was most of the log.
    if (unreadChats.length !== this.lastUnreadLogged) {
      this.lastUnreadLogged = unreadChats.length;
      cblog(`ChatbotEngine: unread=${unreadChats.length}`);
    }
    if (this.cancelled) { this.setActiveContact(null); return; }
    if (unreadChats.length === 0) {
      // Nothing unread at all -> nothing is waiting on us any more.
      if (this.pending.size > 0) cblog(`ChatbotEngine: inbox clear — dropped ${this.pending.size} pending`);
      this.pending.clear();
      // Same decay as 3a: with nothing unread every baseline is 0, or a
      // chat that was unread at start, then read, stays at its old count
      // and its next message (1 > 1 is false) is never answered.
      this.baselineCounts.clear();
      this.setActiveContact(null); return;
    }

    // 2. First poll: build baseline. Don't set lastReplyTime — baseline is
    // for "what was already unread before I joined the meeting", not for
    // suppressing real replies. Cooldown applies only after an actual send.
    if (!this.baselineReady) {
      for (const chat of unreadChats) this.baselineCounts.set(keyOf(chat.name), chat.unread);
      this.baselineReady = true;
      cblog(`ChatbotEngine: baseline=${this.baselineCounts.size} contacts`);
      this.setActiveContact(null);
      return;
    }

    // 3a. Decay baseline for contacts that no longer appear in the
    // unread list — the user read them on their phone, so the next
    // message from that contact is "new" relative to a zero baseline.
    // Without this, a contact that had 3 unread at meeting start, was
    // read on phone, then sends 1 new msg, looks like 1 ≤ 3 and the
    // bot stays silent.
    //
    // Leaving the unread list is also exactly what "the user attended to
    // it" looks like, so any pending reply for that chat is dropped here.
    // That is the whole point of `unattended` mode: answer the phone only
    // after it has rung long enough that nobody else is going to.
    const currentKeys = new Set(unreadChats.map(c => keyOf(c.name)));
    for (const key of [...this.baselineCounts.keys()]) {
      if (!currentKeys.has(key)) this.baselineCounts.set(key, 0);
    }
    for (const key of [...this.pending.keys()]) {
      if (!currentKeys.has(key)) {
        cblog(`ChatbotEngine: drop pending '${key}' — user read it`);
        this.pending.delete(key);
      }
    }

    // 3b. Fold unread count INCREASES into `pending`. The baseline moves
    // immediately so the same message is never counted twice, but the delta
    // is held until the gate actually lets a reply out — in `unattended`
    // mode that can be minutes later, or never.
    //
    // `since` is the FIRST unanswered message, not the latest: someone who
    // keeps typing shouldn't keep pushing their own timer back.
    for (const chat of unreadChats) {
      if (this.cancelled) break;
      const key = keyOf(chat.name);
      const baseline = this.baselineCounts.get(key) ?? 0;
      if (chat.unread > baseline) {
        const delta = chat.unread - baseline;
        this.baselineCounts.set(key, chat.unread);
        const p = this.pending.get(key);
        if (p) {
          p.newCount += delta;
          p.chat = chat;
        } else {
          this.pending.set(key, { chat, newCount: delta, since: new Date(), staleReads: 0 });
        }
      } else {
        const p = this.pending.get(key);
        // Still waiting on this one — refresh the row so a mention
        // badge that only appeared on a later message is seen.
        if (p) p.chat = chat;
      }
    }
    if (this.pending.size === 0) { this.setActiveContact(null); return; }

    // 3c. Decide, per chat, whether a reply goes out now.
    const now = new Date();
    const inMeeting = MeetingDetector.shared.isInMeeting;
    const mode = Settings.waBotMode;
    const groupReplies = Settings.waGroupReplies;
    const unattendedSeconds = Settings.waUnattendedMinutes * 60;
    const blockList = WAContactLists.names("neverReply");
    const quiet = Settings.waQuietHours
      && WABotGate.isQuietHour(now, Settings.waQuietFrom, Settings.waQuietTo);
    const due: Pending[] = [];
    for (const [key, p] of [...this.pending]) {
      const d = WABotGate.decide({
        chat: p.chat, pendingSince: p.since, now,
        inMeeting, mode, groupReplies, unattendedSeconds,
        blocked: WAContactLists.matches(blockList, p.chat.name),
        quietHours: quiet,
      });
      switch (d.kind) {
        case "reply":
          due.push(p);
          this.pending.delete(key);
          break;
        case "wait":
          break;
        case "skip":
          cblog(`ChatbotEngine: skip '${p.chat.name}' — ${d.why}`);
          this.pending.delete(key);
          break;
      }
    }
    if (due.length === 0) { this.setActiveContact(null); return; }
    const draftOnly = Settings.waDraftOnly;
    cblog(`ChatbotEngine: ${draftOnly ? "drafting for" : "replying to"} ${due.length} — ${JSON.stringify(due.map(p => p.chat.name))}`);
    const delivered: Delivered[] = [];

    // 4. Process each due chat.
    for (const p of due) {
      if (this.cancelled) break;
      const chat = p.chat;
      const key = keyOf(chat.name);

      // Cooldown.
      const last = this.lastReplyTime.get(key);
      if (last && (Date.now() - last.getTime()) / 1000 < this.replyCooldown) {
        // Back on the pile, not dropped: a second message a moment after
        // the first is a real message, and the baseline is already past it.
        cblog(`ChatbotEngine: '${chat.name}' in cooldown — answering next poll`);
        this.pending.set(key, p);
        continue;
      }

      // 5. Read only the NEW incoming messages — the ones that arrived
      // while the user wasn't answering. Reading exactly that many
      // incoming bubbles avoids pulling in stale conversation history.
      this.setActiveContact(chat.name);
      await ChromeWhatsApp.clickChat(chat.name);
      // Wait for the message pane to actually populate rather than
      // guessing at a sleep: it is virtualised, and 0.6s measured zero
      // rows on a real chat, which reads as "nothing to say".
      //
      // A pane that never renders is a transient failure, not an empty
      // chat, so the message goes back on the pending pile to be tried
      // again next poll. Dropping it would lose that message for good:
      // the baseline has already moved past it.
      if (!(await ChromeWhatsApp.waitForMessages())) {
        cblog(`ChatbotEngine: '${chat.name}' pane didn't render — retrying next poll`);
        this.pending.set(key, p);
        this.setActiveContact(null); continue;
      }

      // 5b. Second opinion on group-ness, now that the chat is open. The
      // sidebar heuristic can miss (a group whose last message happens to
      // carry no sender prefix), and replying into a group the user never
      // opted into is the expensive mistake.
      if (!chat.isGroup && (await ChromeWhatsApp.openChatIsGroup())) {
        if (!groupReplies || !chat.mentioned) {
          cblog(`ChatbotEngine: '${chat.name}' is a group after all — not replying`);
          this.setActiveContact(null); continue;
        }
      }

      // 5a. The sidebar shows a message before the open pane renders it.
      // Reading too early answered an older message ("Np") instead of the
      // two questions that had just arrived. Wait for the newest incoming
      // bubble to match the preview; if it never does, try next poll --
      // twice, then answer what's there (a photo's preview never matches).
      let thread = await ChromeWhatsApp.readThread();
      const deadline = Date.now() + 4000;
      while (!WABotGate.showsLatest(thread, chat.preview) && Date.now() < deadline) {
        await sleep(400);
        thread = await ChromeWhatsApp.readThread();
      }
      if (!WABotGate.showsLatest(thread, chat.preview) && p.staleReads < 2) {
        cblog(`ChatbotEngine: '${chat.name}' newest message not rendered yet — retrying next poll`);
        this.pending.set(key, { ...p, staleReads: p.staleReads + 1 });
        this.setActiveContact(null); continue;
      }

      // Everything since the last message from this side is unanswered --
      // the unread badge undercounts when two arrive between polls.
      const unanswered: string[] = [];
      for (let i = thread.length - 1; i >= 0 && !thread[i].outgoing; i--) unanswered.unshift(thread[i].text);
      const messages = unanswered.slice(-Math.max(6, p.newCount));
      cblog(`ChatbotEngine: '${chat.name}' new=${p.newCount} msgs=${messages.length}`);

      // Nothing readable -- a sticker, an image, or a sender WhatsApp
      // won't name. Replying anyway handed the model an empty "their
      // latest message" and let it answer something it had never read.
      if (messages.length === 0) {
        cblog(`ChatbotEngine: skip '${chat.name}' — nothing readable in the new messages`);
        this.setActiveContact(null); continue;
      }

      // 5c. The chat around those messages: earlier turns for the prompt,
      // and whether this is two bots answering each other.
      const sent = this.sentByBot.get(key) ?? [];
      const ctx = WABotGate.threadContext(thread, new Date(), text => {
        const t = fingerprint(text);
        return text.toLowerCase().includes("ai assistant") || sent.some(s => fingerprint(s) === t);
      });
      if (ctx.botLoop) {
        cblog(`ChatbotEngine: skip '${chat.name}' — bot-to-bot loop, waiting for a human`);
        this.setActiveContact(null); continue;
      }
      const me = Settings.userName;
      const history = ctx.turns.map(t => ({
        role: t.bot ? "you (the assistant)" : t.outgoing ? `${me} personally` : chat.name,
        text: t.text,
      }));

      // 6. Generate reply.
      // Their own meeting link replaces the one we'd send.
      if (messages.some(containsMeetingLink)) {
        this.cancelMeet(key, "they sent their own link");
      }
      const call = this.meets.get(key);
      const reply = this.llm
        ? await this.llm.reply(chat.name, messages.join(" | "), history, call?.at ?? null, call?.sentAt != null)
        : null;
      if (!reply) {
        cblog(`ChatbotEngine: LLM nil for '${chat.name}'`);
        this.setActiveContact(null); continue;
      }
      const replyText = reply.text;
      if (this.cancelled) break;
      cblog(`ChatbotEngine: reply='${replyText.slice(0, 80)}...'`);

      // 7. Verify we're in the right conversation.
      if (!(await this.chatIsOpen(chat.name))) { this.setActiveContact(null); continue; }
      cblog(`ChatbotEngine: verified '${chat.name}'`);

      // 8. Send -- or, in draft mode, type it and stop.
      const ok = draftOnly ? await ChromeWhatsApp.draftMessage(replyText)
                           : await ChromeWhatsApp.sendMessage(replyText);
      cblog(`ChatbotEngine: ${draftOnly ? "draft" : "send"}=${ok}`);
      if (this.cancelled) break;
      await sleep(300);
      if (!ok) { this.setActiveContact(null); continue; }

      // 9. A task the contact asked for, if the reply pass found one.
      // Fire-and-forget: it no-ops without a connected Google account and
      // must never hold up the next chat in the batch.
      if (reply.meet?.kind === "inMinutes") {
        this.scheduleMeet(key, chat.name, reply.meet.minutes);
      } else if (reply.meet?.kind === "cancel") {
        this.cancelMeet(key, "they called it off");
      }

      if (reply.task) {
        const task = reply.task;
        background("createChatTask", () => GoogleSync.createChatTask(task, chat.name));
      }

      delivered.push({ contact: chat.name, text: replyText, task: reply.task });
      this.lastReplyTime.set(key, new Date());
      // A draft isn't the bot's message until the user sends it; if they
      // do, it's theirs.
      if (!draftOnly) this.sentByBot.set(key, [...(this.sentByBot.get(key) ?? []), replyText].slice(-this.sentCap));
      await sleep(600);
    }

    if (delivered.length > 0) {
      try { this.onRepliesSent?.(delivered, draftOnly); } catch (e) { cblog(`ChatbotEngine: onRepliesSent threw — ${e}`); }
    }
    this.setActiveContact(null);
  }

  // MARK: - Scheduled Meet links

  private scheduleMeet(key: string, contact: string, inMinutes: number): void {
    const at = new Date(Date.now() + inMinutes * 60_000);
    // A call whose link already went out is done; a new ask is a new call.
    const prior = this.meets.get(key);
    const existing = prior && prior.sentAt === null ? prior : null;
    this.meets.set(key, { contact, at, link: existing?.link ?? null, eventId: existing?.eventId ?? null, sentAt: null });
    if (existing?.eventId) {
      cblog(`ChatbotEngine: call with '${contact}' moved to ${at.toString()}`);
      const id = existing.eventId;
      background("moveChatMeet", () => GoogleSync.moveChatMeet(id, at));
    } else if (!existing) {
      cblog(`ChatbotEngine: call with '${contact}' set for ${at.toString()} — creating Meet`);
      Promise.resolve()
        .then(() => GoogleSync.createChatMeet(contact, at) as unknown)
        .catch(e => { cblog(`ChatbotEngine: createChatMeet failed — ${e}`); return null; })
        .then(r => {
          const { link, eventId } = meetResult(r);
          const m = this.meets.get(key);
          if (link === null) { this.meets.delete(key); return; }
          if (m) { m.link = link; m.eventId = eventId; }
          // Moved again while the create was in flight: put the event at the latest time.
          const latest = m?.at;
          if (eventId && latest && latest.getTime() !== at.getTime()) {
            background("moveChatMeet", () => GoogleSync.moveChatMeet(eventId, latest));
          }
        });
    }
    if (this.meetTimer === null) {
      this.meetTimer = setInterval(() => {
        if (this.pollingInProgress || this.held) return;
        this.pollingInProgress = true;
        this.sendDueMeets()
          .catch(e => cblog(`ChatbotEngine: Meet link send failed — ${e}`))
          .finally(() => { this.pollingInProgress = false; });
      }, 15_000);
    }
  }

  private cancelMeet(key: string, why: string): void {
    const m = this.meets.get(key);
    this.meets.delete(key);
    if (!m || m.sentAt !== null) return;
    cblog(`ChatbotEngine: call with '${m.contact}' cancelled — ${why}`);
    if (m.eventId) {
      const id = m.eventId;
      background("deleteChatMeet", () => GoogleSync.deleteChatMeet(id));
    }
  }

  /// Sends every link whose time has come. Runs on the poll (start of each
  /// poll) and from `meetTimer`, never both at once.
  private async sendDueMeets(): Promise<void> {
    for (const [k, m] of [...this.meets]) {
      if (m.sentAt && Date.now() - m.sentAt.getTime() >= 3_600_000) this.meets.delete(k);
    }
    const due = [...this.meets].filter(([, m]) => m.sentAt === null && m.at.getTime() <= Date.now());
    for (const [key, m] of due) {
      if (!m.link) {
        // Event creation failed or never returned: nothing to send.
        if (Date.now() - m.at.getTime() > 120_000) this.cancelMeet(key, "no Meet link was created");
        continue;
      }
      await ChromeWhatsApp.clickChat(m.contact);
      if (!(await ChromeWhatsApp.waitForMessages()) || !(await this.chatIsOpen(m.contact))) {
        if (Date.now() - m.at.getTime() > 300_000) {
          cblog(`ChatbotEngine: gave up sending Meet link to '${m.contact}'`);
          this.meets.delete(key);
        }
        continue;
      }
      const text = `Here's the meeting link for the call: ${m.link}`;
      const draft = Settings.waDraftOnly;
      const ok = draft ? await ChromeWhatsApp.draftMessage(text) : await ChromeWhatsApp.sendMessage(text);
      cblog(`ChatbotEngine: Meet link to '${m.contact}' ${draft ? "drafted" : "sent"}=${ok}`);
      if (ok) {
        const cur = this.meets.get(key);
        if (cur) cur.sentAt = new Date();
        if (!draft) this.sentByBot.set(key, [...(this.sentByBot.get(key) ?? []), text].slice(-this.sentCap));
      }
    }
    const allSent = [...this.meets.values()].every(m => m.sentAt !== null);
    if (allSent && this.meetTimer) { clearInterval(this.meetTimer); this.meetTimer = null; }
  }

  /// Whether the open conversation is `name`'s. No header at all passes, as
  /// it always has: it means WhatsApp's markup moved, not a wrong chat.
  private async chatIsOpen(name: string): Promise<boolean> {
    const header = await ChromeWhatsApp.conversationHeader();
    if (header === null) return true;
    if (!ChromeWhatsApp.headerMatches(header, name)) {
      cblog(`ChatbotEngine: VERIFY FAILED header='${header}' target='${name}' — ABORT`);
      return false;
    }
    return true;
  }

  // MARK: - Helpers

  private setActiveContact(name: string | null): void {
    if (this._activeContactName === name) return;
    this._activeContactName = name;
    bus.emit("activeTexterChanged", name);
  }
}
