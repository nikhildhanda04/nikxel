import type { WABotMode } from "../core/settings";
import type { WAMessage, WAUnreadChat } from "./chromeWhatsApp";

/// The pure parts of the WhatsApp bot — the reply gate, the thread-context
/// reader and the reply-marker parsers — kept free of Electron, Google and the
/// agent runner so checks/waBot.test.ts can load them under plain Node.
/// `ChatbotEngine` and `LLMResponder` re-export them under their Swift names.

// MARK: - Reply gate

/// Whether a given unread chat earns a reply right now. Pulled out of
/// `ChatbotEngine` as a pure function because this is the part with the
/// branches worth checking -- see checks/waBot.test.ts.
export type Decision =
  | { kind: "reply" }
  /// Eligible, but the unattended timer hasn't run out. Stays pending.
  | { kind: "wait" }
  /// Never, for this reason. Dropped.
  | { kind: "skip"; why: string };

/// Whether the poller has any reason to run outside a meeting in this mode.
export function runsOutsideMeetings(mode: WABotMode): boolean {
  return mode !== "meetings";
}

export interface ThreadTurn { outgoing: boolean; bot: boolean; text: string }

/// Letters and digits only, first 40: what WhatsApp renders back (emoji
/// as images, trailing time stripped) rarely matches what was sent exactly.
export function fingerprint(s: string): string {
  return Array.from(s.toLowerCase()).filter(ch => /[\p{L}\p{M}\p{N}]/u.test(ch)).slice(0, 40).join("");
}

/// Someone else's meeting link: theirs replaces the one we'd send.
export function containsMeetingLink(s: string): boolean {
  return /meet\.google\.com\/|meet\.jit\.si\/|zoom\.us\/(j|my)\/|teams\.(microsoft|live)\.com\//i.test(s);
}

export const WABotGate = {
  decide(args: {
    chat: WAUnreadChat;
    pendingSince: Date;
    now: Date;
    inMeeting: boolean;
    mode: WABotMode;
    groupReplies: boolean;
    unattendedSeconds: number;
    blocked?: boolean;
    quietHours?: boolean;
  }): Decision {
    const { chat, pendingSince, now, inMeeting, mode, groupReplies, unattendedSeconds } = args;
    // The never-reply list beats everything, including a live meeting. The
    // whole value of writing a name down is that it then needs no thought.
    if (args.blocked) return { kind: "skip", why: "on your never-reply list" };

    if (chat.isGroup) {
      if (!groupReplies) return { kind: "skip", why: "group chats off" };
      if (!chat.mentioned) return { kind: "skip", why: "group, user not tagged" };
    }
    // A meeting is the one state where every mode answers at once: the
    // point of the feature is covering for someone who cannot type. It also
    // overrides quiet hours -- if you're in a meeting at 3am you're awake.
    if (inMeeting) return { kind: "reply" };

    // Checked after the meeting short-circuit and before the mode, so a
    // message that arrives at 2am is held rather than dropped: `wait`
    // keeps it pending and it goes out once the quiet hours end.
    if (args.quietHours) return { kind: "wait" };

    switch (mode) {
      case "meetings":
        return { kind: "skip", why: "no meeting" };
      case "always":
        return { kind: "reply" };
      case "unattended":
        return (now.getTime() - pendingSince.getTime()) / 1000 >= unattendedSeconds
          ? { kind: "reply" }
          : { kind: "wait" };
    }
  },

  /// What the open chat says around the new messages: the earlier turns to put
  /// in the prompt, and whether two bots are talking to each other.
  ///
  /// `thread` is the rendered chat, oldest first. Its trailing run of incoming
  /// bubbles is the new messages being answered, so context is what came
  /// before them -- at most `limit` turns, none older than `idle`, so a chat
  /// that went quiet starts fresh instead of dragging in this morning's topic.
  ///
  /// `botLoop` is two assistants talking to each other: the other side has
  /// called itself an assistant, and this bot has already replied
  /// `loopCap` times since the user last typed. Left alone, two always-on
  /// bots answer each other forever, a paid agent run per message.
  threadContext(thread: WAMessage[], now: Date, isBot: (text: string) => boolean,
                limit = 5, idleSec = 30 * 60, loopCap = 3): { turns: ThreadTurn[]; botLoop: boolean } {
    // Continuation rows carry no stamp; they belong to the bubble above.
    let at: Date | null = null;
    const stamped = thread.map(m => {
      if (m.at) at = m.at;
      return { m, at: at as Date | null };
    });
    const earlier = stamped.slice();
    while (earlier.length > 0 && !earlier[earlier.length - 1].m.outgoing) earlier.pop();

    const fresh = (a: Date | null) => a !== null && (now.getTime() - a.getTime()) / 1000 <= idleSec;
    const recent = stamped.filter(s => fresh(s.at));
    let lastUser = -1;
    for (let i = recent.length - 1; i >= 0; i--) {
      if (recent[i].m.outgoing && !isBot(recent[i].m.text)) { lastUser = i; break; }
    }
    const sinceUser = lastUser >= 0 ? recent.slice(lastUser + 1) : recent;
    const botReplies = sinceUser.filter(s => s.m.outgoing).length;
    const otherIsBot = sinceUser.some(s => !s.m.outgoing && s.m.text.toLowerCase().includes("assistant"));
    const botLoop = botReplies >= loopCap && otherIsBot;

    const turns = earlier
      .filter(s => fresh(s.at))
      .slice(-limit)
      .map(s => ({ outgoing: s.m.outgoing, bot: s.m.outgoing && isBot(s.m.text), text: s.m.text }));
    return { turns, botLoop };
  },

  /// Whether the open chat has rendered the message the sidebar previews: its
  /// newest incoming bubble matches. An empty preview can't be checked.
  showsLatest(thread: WAMessage[], preview: string): boolean {
    const want = fingerprint(preview);
    if (!want) return true;
    let last: WAMessage | undefined;
    for (let i = thread.length - 1; i >= 0; i--) if (!thread[i].outgoing) { last = thread[i]; break; }
    if (!last) return false;
    const got = fingerprint(last.text);
    return got !== "" && (got.startsWith(want) || want.startsWith(got));
  },

  /// Whether `date` falls inside the quiet window, wrapping past midnight
  /// when `from` is later than `to` (22→8, the normal case). `from == to` is
  /// treated as no quiet hours rather than all of them: a zero-length window
  /// is what you get from a half-filled settings file, and silencing the bot
  /// completely is what the Off switch is for.
  isQuietHour(date: Date, from: number, to: number): boolean {
    if (from === to) return false;
    const h = date.getHours();
    return from < to ? (h >= from && h < to) : (h >= from || h < to);
  },
};

// MARK: - Reply markers (LLMResponder)

/// A call the contact proposed, moved or called off.
export type MeetAsk = { kind: "inMinutes"; minutes: number } | { kind: "cancel" };

/// `[[MEET: 20]]` -> in 20 minutes, `[[MEET: cancel]]` -> call off. Anything
/// else, or a time outside 1 min..12 h, is ignored rather than guessed at.
export function parseMeet(value: string | null | undefined): MeetAsk | null {
  if (value === null || value === undefined) return null;
  const v = value.trim().toLowerCase();
  if (v === "cancel") return { kind: "cancel" };
  if (!/^[+-]?\d+$/.test(v)) return null;
  const n = parseInt(v, 10);
  if (n < 1 || n > 720) return null;
  return { kind: "inMinutes", minutes: n };
}

/// `[[NAME: value]]` markers: first non-empty, non-"none" value, and the
/// text with every such marker removed.
export function extractMarker(name: string, raw: string): { body: string; value: string | null } {
  let value: string | null = null;
  let body = raw;
  const openTag = `[[${name}:`;
  for (;;) {
    const open = body.indexOf(openTag);
    if (open < 0) break;
    const close = body.indexOf("]]", open + openTag.length);
    if (close < 0) break;
    const inner = body.slice(open + openTag.length, close).trim();
    if (value === null && inner !== "" && inner.toLowerCase() !== "none") value = inner;
    body = body.slice(0, open) + body.slice(close + 2);
  }
  return { body: body.trim(), value };
}

/// Pulls `[[TASK: ...]]` markers out of a raw reply and hands back the
/// message with them removed.
///
/// A marker rather than a second LLM call: the agent is already reading the
/// message to answer it, so asking for one extra line costs nothing. Only
/// the first marker is kept -- one message is one ask, and a model that
/// emits five has misunderstood the instruction.
export function extractTask(raw: string): { body: string; task: string | null } {
  const { body, value } = extractMarker("TASK", raw);
  return { body, task: value };
}
