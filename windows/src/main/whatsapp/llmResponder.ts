import type { MOMGenerator } from "../recording/momGenerator";
import { DayLogger } from "../system/dayLogger";
import { nikxelPath, readText, writeAtomic } from "../core/paths";
import { Settings } from "../core/settings";
import { cblog } from "../core/diag";
import { MeetingDetector } from "./meetingDetector";
import { WAContactLists } from "./waContactLists";
import { extractMarker, extractTask, parseMeet, type MeetAsk } from "./waBotGate";

export type { MeetAsk } from "./waBotGate";

/// What came back from one reply pass: the message to send, and -- when the
/// contact actually asked for something -- a task to file.
export interface Reply {
  text: string;
  /// Short imperative pulled out of the contact's message, e.g. "Send the
  /// deck to Priya by Friday". null when they weren't asking for anything.
  task: string | null;
  /// A call the contact proposed, moved or called off.
  meet: MeetAsk | null;
}

/// "h:mm a", e.g. "3:05 PM".
function clockTime(d: Date): string {
  const h = d.getHours() % 12 === 0 ? 12 : d.getHours() % 12;
  return `${h}:${String(d.getMinutes()).padStart(2, "0")} ${d.getHours() < 12 ? "AM" : "PM"}`;
}

/// DayLogger.recentSummaries is `[(day, text)]` in Swift; the Windows port
/// may hand back that list (as tuples or objects) or the block pre-joined as
/// one string. Accept all three so the bot's memory survives either shape.
function summaryBlocks(raw: unknown): string[] {
  if (typeof raw === "string") return raw.trim() ? [raw.trim()] : [];
  if (!Array.isArray(raw)) return [];
  const out: string[] = [];
  for (const e of raw) {
    let day: unknown, text: unknown;
    if (Array.isArray(e)) [day, text] = e;
    else if (e && typeof e === "object") ({ day, text } = e as { day?: unknown; text?: unknown });
    if (typeof day === "string" && typeof text === "string") out.push(`--- ${day} ---\n${text}`);
  }
  return out;
}

/// LLM response generation. Uses the existing MOMGenerator agent pipeline
/// but with a chat-personality prompt instead of a meeting-summary prompt.
export class LLMResponder {
  static readonly parseMeet = parseMeet;
  static readonly extractTask = extractTask;
  static readonly extractMarker = extractMarker;

  readonly personalityPath: string;

  constructor(private readonly momGenerator: MOMGenerator) {
    this.personalityPath = nikxelPath("bot_personality.txt");
  }

  /// Load the bot personality from disk — or write the default.
  get personality(): string {
    const content = readText(this.personalityPath)?.trim();
    if (content) return content;
    const name = Settings.userName;
    const def = `You are ${name}'s friendly AI assistant. You're responding to WhatsApp messages ` +
      `while ${name} is in a meeting. Be casual, warm, and helpful. Keep responses ` +
      `concise (1-3 sentences). Be honest -- say you're ${name}'s assistant, don't ` +
      `pretend to be ${name}. If you don't know something, say so.`;
    try { writeAtomic(this.personalityPath, def); } catch { /* read-only home: use the default unsaved */ }
    return def;
  }

  /// Generate a reply for a contact based on their message preview and
  /// previous conversation history.
  /// `scheduledCall` is a call already set with this contact, so "give me 5
  /// more minutes" can move it; `linkSent` says its Meet link already went.
  async reply(contact: string,
              messagePreview: string | null,
              history: { role: string; text: string }[],
              scheduledCall: Date | null = null,
              linkSent = false): Promise<Reply | null> {
    const msgs = messagePreview !== null ? [messagePreview] : [];
    const prompt = this.buildPrompt(contact, history, msgs, scheduledCall, linkSent);
    try {
      // ponytail: Haiku hardcoded -- a 1-3 sentence reply doesn't need a
      // bigger model, and it's ~2x faster. Make it a setting if replies
      // ever need more reasoning.
      const raw = await this.momGenerator.runPrompt(prompt, "whatsapp", "haiku");
      // Task marker first: cleanReply truncates to three sentences, which
      // would eat a trailing marker before it was ever read.
      const { body: afterTask, task } = extractTask(raw);
      const { body, value: meet } = extractMarker("MEET", afterTask);
      const text = this.cleanReply(body);
      if (text === null) return null;
      return { text, task, meet: parseMeet(meet) };
    } catch (e) {
      cblog(`LLMResponder: failed — ${e instanceof Error ? e.message : e}`);
      return null;
    }
  }

  private buildPrompt(contact: string,
                      history: { role: string; text: string }[],
                      newMessages: string[],
                      scheduledCall: Date | null,
                      linkSent: boolean): string {
    const trusted = WAContactLists.contains("trusted", contact);
    let p = this.personality + "\n\n";
    p += this.recentContextBlock(trusted);
    p += `Contact: ${contact}${trusted ? ` (one of ${Settings.userName}'s own people)` : ""}\n`;
    if (history.length > 0) {
      p += "\nRecent chat, oldest first (for context -- don't repeat what was already said):\n";
      for (const { role, text } of history.slice(-6)) {
        p += `- ${role}: ${text}\n`;
      }
    }
    p += "\nTheir latest message(s):\n";
    for (const msg of newMessages) p += `- ${msg}\n`;
    p += "\nRespond in character. Keep it under 3 sentences. No markdown. No code blocks.\n";
    if (Settings.waChatTasks) {
      p += `
If -- and only if -- their message contains a concrete thing ` +
        `${Settings.userName} has to DO (a request, a deadline, ` +
        `something to send or check), add one final line in exactly this ` +
        `form, after your reply:
[[TASK: <short imperative, under 12 words>]]
Keep any date or name they gave inside the title ("Send the deck to ` +
        `Priya by Friday"). The line is stripped before the message is sent ` +
        `and the contact never sees it. If they were only chatting, asking ` +
        `how you are, or sharing news, add nothing -- an empty inbox is worth ` +
        `more than an invented task.
`;
    }
    {
      const name = Settings.userName;
      const callNote = scheduledCall === null ? "" : linkSent
        ? ` A call with this contact was set for ${clockTime(scheduledCall)} and its meeting link is already in the chat -- if they ask for more time, just acknowledge it; no MEET line.`
        : ` A call with this contact is already set for ${clockTime(scheduledCall)}; a meeting link goes to them then. If they ask for more time, push it later: the set time plus that delay (or now plus it, if the set time has passed).`;
      p += `
Current time: ${clockTime(new Date())}.${callNote}
If they propose a call or meeting with ${name} at a time or after a ` +
        `delay ("let's connect in 20 mins", "call at 6", "give me 5 more ` +
        `minutes", "after 30"), add one final line: [[MEET: <whole minutes ` +
        `from now until the call>]]. If they call it off, add [[MEET: cancel]]. If they ` +
        `sent their own meeting link, or just chatted, add nothing. When you ` +
        `add a MEET line, say in your reply that you'll send a meeting ` +
        `link at that time. The line is stripped before sending.
`;
    }
    p += Settings.languageInstruction;
    if (Settings.language.toLowerCase() === "auto") {
      p += " Match the contact's own language/tone — if they write in Hindi or Hinglish, reply the same way; if they write in English, reply in English.";
    }
    return p;
  }

  /// Everything the bot knows about what the user is up to: what they are
  /// doing right now, how today has gone so far, and the last few end-of-day
  /// summaries. Lets it answer "any update on X?" instead of "I'm not sure,
  /// I'll pass it on".
  ///
  /// These are detailed -- repos and commits, window titles, which apps were
  /// used, who else was messaged and called. The bot replies automatically to
  /// whoever happens to write, including people who should not learn any of
  /// that, so the block is wrapped in an explicit non-disclosure rule.
  /// Context for understanding the question; not material to volunteer.
  ///
  /// Not private: a check prints this block and feeds it to a real agent to
  /// confirm the non-disclosure rules actually hold.
  recentContextBlock(trusted = false): string {
    const days = Settings.botMemoryDays;
    const summaries = days > 0 ? summaryBlocks(DayLogger.recentSummaries(days) as unknown) : [];
    const live = Settings.waWorkContext
      ? (DayLogger.current?.liveContext(MeetingDetector.shared.isInMeeting) ?? "")
      : "";
    if (summaries.length === 0 && !live) return "";

    const user = Settings.userName;
    // Two rule sets over the same material. The strict one is the default
    // because the bot answers whoever happens to write; the relaxed one
    // applies only to names the user put on the trusted list by hand.
    let block = trusted
      ? `BACKGROUND -- ${user}'s own notes on what they are ` +
        `doing. This contact is on their trusted list, so you may answer from ` +
        `this directly: name the project, say what was built or committed, say ` +
        `what the meeting was about.

Still holds, even here:
- Don't mention these notes exist, and don't say you have access to a log. ` +
        `Speak as someone who simply knows what they're up to.
- Don't pass on what OTHER people said in confidence, or details about ` +
        `third parties and their clients. Their own work, yes; everyone else's, no.
- People name work loosely: a task means whichever repo, branch, file ` +
        `or function shares its words ("the produce POS task" -> a repo named ` +
        `pos-new; "the Datacap bug" -> a datacap branch or file). Match on ` +
        `overlapping words and answer from ` +
        `the closest match: what was edited or committed there and when, ` +
        `newest first. Don't ask them which one they mean if one fits.
- Don't invent. But a partial answer beats none: if the notes show ` +
        `when it was last worked on, or what's in progress around it, say that ` +
        `("worked on the Datacap cert logs on the 3rd, POS backend fixes since") ` +
        `and add that they'll confirm the latest. Only if nothing in here ` +
        `touches it, say you're not sure.

`
      : `BACKGROUND -- ${user}'s own notes on what they are ` +
        `doing. This is private. Use it only to understand what the contact is ` +
        `asking about and to answer naturally when they raise something you ` +
        `recognise.

Never disclose from it. Specifically:
- Don't volunteer project, repo, client or company names, what was built or ` +
        `committed, meeting topics, or who else they met, called or messaged.
- Don't mention these notes exist, and don't say you have access to a log.
- If asked what they're working on, stay general ("heads-down on work stuff") ` +
        `unless this contact clearly already knows the specifics from the conversation.
- If a question needs a detail that's only in here, say they'll follow up ` +
        `themselves rather than answering from it.
- Whether they are in a meeting or free right now IS fine to share -- that ` +
        `is the one thing a person waiting on a reply actually needs to know.

`;
    if (live) block += `RIGHT NOW:\n${live}\n\n`;
    for (const s of summaries) block += `${s}\n\n`;
    block += "END OF BACKGROUND.\n\n";
    return block;
  }

  private cleanReply(raw: string): string | null {
    let s = raw
      .replace(/\*{1,3}([^*]+)\*{1,3}/g, "$1")
      .replace(/`{1,3}[^`]*`{1,3}/g, "")
      .split("```").join("")
      .trim();
    s = s.split("\n")
      .filter(l => !l.startsWith("#"))
      .join("\n")
      .trim();
    if (!s) return null;
    const sentences = s.split(". ").filter(x => x !== "").slice(0, 3);
    const short = sentences.join(". ");
    return short.endsWith(".") ? short : short + ".";
  }
}
