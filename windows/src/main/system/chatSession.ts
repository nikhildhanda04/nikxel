import { shell } from "electron";
import * as path from "path";
import { cblog } from "../core/diag";
import { Settings } from "../core/settings";
import { documentsRoot } from "../core/paths";
import { MOMError, MOMGenerator } from "../recording/momGenerator";
import { CAP, build, localBlocks, openTarget, projectBlocks, prompt } from "./chatContext";
import * as SummaryLibrary from "./summaryLibrary";
import { CloudSync } from "./cloudSync";
import * as ERP from "./erp";
import * as Slack from "./slack";
import { ChromeWhatsApp, WAMessage } from "../whatsapp/chromeWhatsApp";
import { ChatbotEngine } from "../whatsapp/chatbotEngine";
import * as WAChatMatch from "../whatsapp/waChatMatch";
import { DayLogger } from "./dayLogger";
import { MeetingDetector } from "../whatsapp/meetingDetector";
import { GoogleAuth } from "../google/googleAuth";
import * as Gmail from "../google/gmail";
import * as MailIntent from "../google/mailIntent";

/// One conversation with Nikxel: what the avatar's floating chat runs (and, on
/// the Mac, the Nikxel window's Chat section). It reads the inbox and the project
/// feed once as it starts, WhatsApp again for each question (and opens any chat
/// the question names, waChatMatch.ts), then answers
/// from those, what Nikxel knows about the user, what's happening right now, and
/// the last two weeks of summaries (ChatContext). Mail commands and "make a task
/// to …" are handled here, never by the model. Port of src/ChatSession.swift;
/// the mic stays in avatarChat.ts, since Windows records in the renderer.

const root = () => path.join(documentsRoot(), "nikxel");

type MailOutcome = { kind: "none" } | { kind: "reply"; text: string } | { kind: "context"; text: string };

export class ChatSession {
  history: { q: string; a: string }[] = [];
  private waSnapshot = "";   // the latest read of WhatsApp (unread, recent chats, open thread)
  private mailSnapshot = ""; // the inbox at open time, when Gmail is connected
  private knownMailIds = new Set<string>(); // ids the chat has shown the model; labels only touch these
  private lastDraftId: string | null = null; // what "send it" sends
  private feed: { feed: any[]; offline: boolean } = { feed: [], offline: true };
  private readonly ready: Promise<void>;

  constructor(readonly agent: MOMGenerator) {
    this.ready = Promise.all([
      CloudSync.projectFeed(CloudSync.getter(3000)).then(f => { this.feed = f; }).catch(() => {}),
      ChatSession.waContextBlock().then(s => { this.waSnapshot = s ?? ""; }),
      this.mailContextBlock().then(s => { this.mailSnapshot = s; }),
    ]).then(() => {});
  }

  /// What this chat can see, for the window's context panel: [{name, detail, on}].
  /// Waits for the start-up reads.
  async sources(): Promise<{ name: string; detail: string; on: boolean }[]> {
    await this.ready;
    const local = localBlocks(root(), new Date());
    const count = (kind: string, one: string) => {
      const n = local.filter(b => b.kind === kind).length;
      return n === 0 ? "None in the last 14 days" : `${n} ${one}${n === 1 ? "" : "s"} from the last 14 days`;
    };
    const has = (kind: string) => local.some(b => b.kind === kind);
    const about = Settings.userContext.trim();
    const projects = projectBlocks(this.feed.feed);
    return [
      { name: "About you", detail: about ? about.slice(0, 140) : "Nothing yet. Add it under You.", on: !!about },
      { name: "Right now", detail: "The app you're in and what you've done today.", on: DayLogger.current !== null },
      { name: "Meetings", detail: count("meeting", "set of minutes"), on: has("meeting") },
      { name: "Days", detail: count("daily", "day summary").replace("summarys", "summaries"), on: has("daily") },
      { name: "Notes", detail: count("note", "note"), on: has("note") },
      { name: "Projects", detail: this.feed.offline ? "Team dashboard not reachable." : `${new Set(projects.map(p => p.name)).size} projects on your team dashboard.`, on: !this.feed.offline && projects.length > 0 },
      { name: "WhatsApp", detail: this.waSnapshot ? "Unread, recent chats and the open thread." : "Not open or not logged in.", on: !!this.waSnapshot },
      { name: "Gmail", detail: this.mailSnapshot ? "Your inbox: search, draft, label, send." : (GoogleAuth.shared.isAuthorized ? "Reconnect Google to give me your mail." : "Connect Google to search, draft and tidy mail."), on: !!this.mailSnapshot },
      { name: "Forklyft ERP", detail: ERP.isConnected() ? "Say “make a task to …” to create one." : "Not connected.", on: ERP.isConnected() },
    ];
  }

  /// Answers `text` with {text, offline, error}. `attach` goes into the context
  /// only (an automation's meeting summary), so what it says can't be taken as a
  /// mail or ERP command.
  async send(text: string, attach = ""): Promise<{ text: string; offline: boolean; error: boolean }> {
    // "open my latest meeting summary": opened here, never left to the model, which can only answer in words.
    const library = SummaryLibrary.scan(), i = attach ? null : openTarget(text, library);
    if (i !== null) {
      const e = library[i];
      // Required here: dashboardWindow imports this file.
      (require("./dashboardWindow") as typeof import("./dashboardWindow")).openSummary(e.file);
      const shelf = ({ meetings: "Meetings", daily: "Days", weekly: "Weeks", notes: "Notes" } as Record<string, string>)[e.kind] ?? "Library";
      const reply = `Opened “${e.title}” in the Nikxel window. You'll find it any time under Library → ${shelf}. It's saved only on this computer.`;
      this.history.push({ q: text, a: reply });
      return { text: reply, offline: false, error: false };
    }
    const history = [...this.history], today = new Date();
    await this.ready;
    const { feed, offline } = this.feed;
    // WhatsApp as it is now, not as it was when the chat opened, plus
    // any chat the question names, opened and read in full.
    this.waSnapshot = (await ChatSession.waContextBlock()) ?? "";
    const named = (await this.waNamedThreads(text)) ?? "";
    const finish = (reply: string, answered: boolean) => {
      if (answered) this.history.push({ q: text, a: reply });
      return { text: reply, offline, error: !answered };
    };
    // What Nikxel has learned about the user (names, projects, people) goes first.
    // What Nikxel is doing right now and has done today (apps, code, agent asks),
    // then the WhatsApp read, then the written summaries/notes/projects.
    const live = DayLogger.current ? "### right now\n" + (await DayLogger.current.liveContextAsync(MeetingDetector.shared.isInMeeting)) : "";
    // Live connection state, so "is my Gmail connected?" isn't answered from old notes.
    const g = GoogleAuth.shared, yn = (b: boolean) => b ? "connected" : "not connected";
    const status = "### connected right now (live; trust this over anything in older notes)\n" +
      `Google: ${yn(g.isAuthorized)}; Gmail: ${yn(g.isAuthorized && g.hasScope("https://www.googleapis.com/auth/gmail.modify"))}; ` +
      `Calendar: ${yn(g.isAuthorized && g.hasScope("https://www.googleapis.com/auth/calendar.readonly"))}; ` +
      `WhatsApp: ${yn(Settings.whatsappConnected)}; WhatsApp auto-reply: ${Settings.botEnabled ? "on" : "off"}; ` +
      `Slack: ${yn(Slack.isConnected())}; ERP: ${yn(ERP.isConnected())}; Organization: ${yn(CloudSync.token() !== null)}`;
    let context = [Settings.userContextBlock, attach, live, status, named, this.waSnapshot, this.mailSnapshot,
      build([...localBlocks(root(), today), ...projectBlocks(feed)], CAP)].filter(x => x).join("\n\n");
    // Mail: "send it", drafts and labels answer here; a search adds to the context.
    const m = await this.handleMail(text, context, history, today);
    if (m.kind === "reply") return finish(m.text, true);
    if (m.kind === "context") context += "\n\n" + m.text;
    // "make a task to …" creates one in ERP, drafted from the same
    // meeting/WhatsApp/project context, then opens it to review.
    if (ERP.looksLikeTaskRequest(text)) return finish(await ChatSession.makeERPTask(text, context, today, this.agent), true);
    try {
      const a = (await this.agent.runPrompt(prompt(context, history, text, today), "chat", "haiku", 30)).trim();
      cblog(`ChatSession: ${context.length} chars of context, answered`);
      return finish(a, true);
    } catch (e) {
      if (e instanceof MOMError && e.kind === "agentNotFound") return finish("Connect Claude in Settings to use chat.", false);
      cblog(`ChatSession: ${context.length} chars of context, failed`);
      return finish("⚠︎ " + (e as Error).message, false);
    }
  }

  /// Draft an ERP task from the chat request plus context, create it, and open
  /// the record to review — the chat-side twin of the summary's Assign button.
  private static async makeERPTask(request: string, context: string, today: Date, agent: MOMGenerator): Promise<string> {
    if (!ERP.isConnected()) return "Connect Forklyft ERP in Nikxel first, then ask again.";
    if (!(await ERP.hasLiveSession())) return "Your ERP session has ended — reconnect Forklyft ERP from the Nikxel menu, then try again.";
    let draftReply: string; // context already carries the live activity + WhatsApp read
    try {
      draftReply = await agent.runPrompt(ERP.taskDraftPrompt(request, context, today), "erp-task", "haiku", 30);
    } catch (e) {
      return e instanceof MOMError && e.kind === "agentNotFound" ? "Connect Claude in Settings to use chat." : "⚠︎ " + (e as Error).message;
    }
    const draft = ERP.parseTaskDraft(draftReply);
    if (!draft) return "I couldn't turn that into a task. Try naming what to do, e.g. “make a task to send Piyush the invoice by Friday”.";
    const r = await ERP.createTaskFromDraft(draft);
    if (!r.url) return r.error ?? "ERP didn't create the task.";
    void shell.openExternal(r.url);
    let line = `Created “${draft.title}” in ERP`;
    if (draft.assignee) line += ` · for ${draft.assignee}`;
    if (draft.project) line += ` · ${draft.project}`;
    if (draft.due) line += ` · due ${draft.due}`;
    return line + ". Opening it so you can review and edit.";
  }

  /// Sending is decided here, never by the model: only "send it" for the draft this
  /// chat made. Everything else mail-like goes through the router.
  private async handleMail(text: string, context: string, history: { q: string; a: string }[], today: Date): Promise<MailOutcome> {
    const reply = (t: string): MailOutcome => ({ kind: "reply", text: t });
    if (MailIntent.isSendCommand(text)) {
      if (!this.lastDraftId) return reply("There's no draft from this chat to send.");
      if (!(await Gmail.sendDraft(this.lastDraftId))) return reply("Gmail didn't send it. The draft is still in your Drafts.");
      this.lastDraftId = null;
      return reply("Sent.");
    }
    if (!MailIntent.looksLikeMail(text) || !GoogleAuth.shared.isAuthorized) return { kind: "none" };
    if (!Gmail.isReady()) return reply("Reconnect Google from the Nikxel menu to give me your mail.");
    let routed: string;
    try {
      routed = await this.agent.runPrompt(MailIntent.routerPrompt(text, context, history, today), "mail", "haiku", 30);
    } catch { return { kind: "none" }; }
    const a = MailIntent.parseAction(routed);
    switch (a.kind) {
      case "answer":
        return { kind: "none" };
      case "search": {
        const found = await Gmail.search(a.query);
        for (const m of found) this.knownMailIds.add(m.id);
        return { kind: "context", text: MailIntent.searchBlock(a.query, found) };
      }
      case "draft": {
        const original = a.draft.replyTo && this.knownMailIds.has(a.draft.replyTo) ? await Gmail.message(a.draft.replyTo) : null;
        const draft = { ...a.draft };
        if (original) {
          if (!draft.to) draft.to = original.from;
          if (!draft.subject) draft.subject = /^re:/i.test(original.subject) ? original.subject : `Re: ${original.subject}`;
        }
        if (!draft.to) return reply("Who should it go to? Give me a name from your mail or an address.");
        const made = await Gmail.createDraft(draft, original);
        if (!made) return reply("Gmail didn't save the draft.");
        this.lastDraftId = made.draftId;
        void shell.openExternal(`https://mail.google.com/mail/u/0/#drafts?compose=${made.messageId}`);
        return reply(`Draft to ${draft.to} — “${draft.subject}”. Opened in Gmail; say “send it” to send.`);
      }
      case "label": {
        const known = a.ids.filter(id => this.knownMailIds.has(id));
        if (!known.length) return reply("I couldn't tell which emails you meant.");
        if (!(await Gmail.modify(known, a.op))) return reply("Gmail didn't make that change.");
        const verb = { archive: "Archived", read: "Marked read:", unread: "Marked unread:", star: "Starred" }[a.op];
        return reply(`${verb} ${known.length} email${known.length === 1 ? "" : "s"}.`);
      }
    }
  }

  /// The inbox at open time, when Gmail is connected; its ids go into knownMailIds.
  private async mailContextBlock(): Promise<string> {
    if (!Gmail.isReady()) return "";
    try {
      const { unread, recent } = await Gmail.inbox();
      for (const m of [...unread, ...recent]) this.knownMailIds.add(m.id);
      return MailIntent.contextBlock(unread, recent);
    } catch { return ""; }
  }

  /// A read of WhatsApp for the chat: who's waiting (unread), the recent chats,
  /// and the thread on screen in full — best-effort, no chat switching, only when
  /// WA is up and logged in. null when there's nothing.
  private static async waContextBlock(): Promise<string | null> {
    try {
      if (!(await ChromeWhatsApp.isLoggedIn())) return null;
      const parts: string[] = [];
      const unread = await ChromeWhatsApp.unreadChats();
      if (unread.length) parts.push("Unread (who's waiting on you):\n" + unread.slice(0, 15).map(c => `- ${c.name} (${c.unread}): ${c.preview.slice(0, 140)}`).join("\n"));
      const recent = await ChromeWhatsApp.allChatsPreview(25);
      if (recent.length) parts.push("Recent chats (newest first):\n" + recent.map(c => `- ${c.name}: ${c.preview.slice(0, 140)}`).join("\n"));
      // readThread (not readMessages) keeps direction, so each line is labelled by
      // who sent it — otherwise the chat can't tell your words from theirs.
      const thread = await ChromeWhatsApp.readThread();
      if (thread.length) {
        const who = (await ChromeWhatsApp.conversationHeader()) ?? "them";
        const lines = thread.slice(-14).map(m => `${m.outgoing ? "You" : m.sender || who}: ${m.text}`);
        parts.push(`Open thread with ${who} (each line is labelled with who sent it):\n` + lines.join("\n"));
      }
      if (!parts.length) return null;
      return "### whatsapp\n" + parts.join("\n\n");
    } catch { return null; }
  }

  /// The chats a question names, opened and read now: "what did Piyush say
  /// in the Nikxel group" reads the chats whose names share a word with it.
  /// Opening a chat marks it read in WhatsApp, as it would on the phone.
  /// Afterwards the chat that was open before is opened again.
  /// The chats the last question read: "and yesterday?" reads them again.
  private lastWANames: string[] = [];

  private async waNamedThreads(question: string): Promise<string | null> {
    try {
      if (!(await ChromeWhatsApp.isLoggedIn())) return null;
      const day = WAChatMatch.day(question);
      let names = WAChatMatch.named(question, (await ChromeWhatsApp.allChatsPreview(60)).map(c => c.name));
      if (!names.length && day) names = this.lastWANames;
      if (!names.length) return null;
      this.lastWANames = names;
      const when = (d: Date) => d.toLocaleString("en-IN", { day: "numeric", month: "short", hour: "numeric", minute: "2-digit" }) + " ";
      const parts: string[] = [];
      await ChatbotEngine.shared.withPollingHeld(async () => {
        const back = await ChromeWhatsApp.conversationHeader();
        for (const name of names) {
          if (!(await ChromeWhatsApp.clickChat(name)) || !(await ChromeWhatsApp.waitForMessages())) continue;
          // A day asked about: scroll back to it and read that day; else the latest 40.
          let thread: WAMessage[];
          if (day) {
            const end = new Date(day.getFullYear(), day.getMonth(), day.getDate() + 1);
            // Bubbles in a run carry no stamp: they take the one above.
            let last: Date | null = null;
            thread = (await ChromeWhatsApp.readBack(day)).map(m => ({ ...m, at: (last = m.at ?? last) }))
              .filter(m => m.at && m.at >= day && m.at < end);
          } else {
            thread = (await ChromeWhatsApp.readThread()).slice(-40);
          }
          if (!thread.length) continue;
          parts.push(`${name}, read just now (each line: when, who, what):\n` + thread.slice(-200).map(m =>
            `${m.at ? when(m.at) : ""}${m.outgoing ? "You" : m.sender || name}: ${m.text.slice(0, 500)}`).join("\n"));
        }
        if (back && !names.includes(back)) await ChromeWhatsApp.clickChat(back);
        return true;
      });
      cblog(`ChatSession: read ${parts.length} of ${names.length} WhatsApp chats the question named${day ? ` (back to ${day.toISOString()})` : ""}`);
      return parts.length ? "### whatsapp chats you asked about\n" + parts.join("\n\n") : null;
    } catch { return null; }
  }
}
