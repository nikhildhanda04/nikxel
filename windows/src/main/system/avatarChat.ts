import { BrowserWindow, ipcMain, Rectangle, screen, shell } from "electron";
import * as path from "path";
import { cblog } from "../core/diag";
import { Settings } from "../core/settings";
import { documentsRoot, nikxelPath, preloadPath, readText, rendererPath, writeAtomic } from "../core/paths";
import { MOMError, MOMGenerator } from "../recording/momGenerator";
import { Transcriber } from "../recording/transcriber";
import { wavHeader } from "../recording/wavWriter";
import { CAP, build, localBlocks, projectBlocks, prompt } from "./chatContext";
import { CloudSync } from "./cloudSync";
import * as ERP from "./erp";
import { ChromeWhatsApp } from "../whatsapp/chromeWhatsApp";
import { DayLogger } from "./dayLogger";
import { MeetingDetector } from "../whatsapp/meetingDetector";
import { GoogleAuth } from "../google/googleAuth";
import * as Gmail from "../google/gmail";
import * as MailIntent from "../google/mailIntent";

/// The chat a single click on the avatar opens (no panel, just bubbles and a field floating beside it): ask about your last two weeks of meetings, days, notes and
/// projects. Clicking the avatar again or Esc closes it, and forgets the conversation. Port of src/AvatarChat.swift.

let current: BrowserWindow | null = null;
let seq = 0;
const W = 340, H = 460, gap = 4;

/// Draft an ERP task from the chat request plus context, create it, and open the
/// record to review — the chat-side twin of the summary's Assign button.
async function makeERPTask(request: string, context: string, today: Date, agent: MOMGenerator): Promise<string> {
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

/// This chat's mail state: ids the model has been shown (labels only touch these) and
/// the draft "send it" sends.
interface MailState { known: Set<string>; lastDraftId: string | null }
type MailOutcome = { kind: "none" } | { kind: "reply"; text: string } | { kind: "context"; text: string };

/// Sending is decided here, never by the model: only "send it" for the draft this chat
/// made. Everything else mail-like goes through the router. Port of AvatarChat.handleMail.
async function handleMail(text: string, context: string, history: { q: string; a: string }[], today: Date,
  agent: MOMGenerator, st: MailState): Promise<MailOutcome> {
  const reply = (t: string): MailOutcome => ({ kind: "reply", text: t });
  if (MailIntent.isSendCommand(text)) {
    if (!st.lastDraftId) return reply("There's no draft from this chat to send.");
    if (!(await Gmail.sendDraft(st.lastDraftId))) return reply("Gmail didn't send it. The draft is still in your Drafts.");
    st.lastDraftId = null;
    return reply("Sent.");
  }
  if (!MailIntent.looksLikeMail(text) || !GoogleAuth.shared.isAuthorized) return { kind: "none" };
  if (!Gmail.isReady()) return reply("Reconnect Google from the Nikxel menu to give me your mail.");
  let routed: string;
  try {
    routed = await agent.runPrompt(MailIntent.routerPrompt(text, context, history, today), "mail", "haiku", 30);
  } catch { return { kind: "none" }; }
  const a = MailIntent.parseAction(routed);
  switch (a.kind) {
    case "answer":
      return { kind: "none" };
    case "search": {
      const found = await Gmail.search(a.query);
      for (const m of found) st.known.add(m.id);
      return { kind: "context", text: MailIntent.searchBlock(a.query, found) };
    }
    case "draft": {
      const original = a.draft.replyTo && st.known.has(a.draft.replyTo) ? await Gmail.message(a.draft.replyTo) : null;
      const draft = { ...a.draft };
      if (original) {
        if (!draft.to) draft.to = original.from;
        if (!draft.subject) draft.subject = /^re:/i.test(original.subject) ? original.subject : `Re: ${original.subject}`;
      }
      if (!draft.to) return reply("Who should it go to? Give me a name from your mail or an address.");
      const made = await Gmail.createDraft(draft, original);
      if (!made) return reply("Gmail didn't save the draft.");
      st.lastDraftId = made.draftId;
      void shell.openExternal(`https://mail.google.com/mail/u/0/#drafts?compose=${made.messageId}`);
      return reply(`Draft to ${draft.to} — “${draft.subject}”. Opened in Gmail; say “send it” to send.`);
    }
    case "label": {
      const known = a.ids.filter(id => st.known.has(id));
      if (!known.length) return reply("I couldn't tell which emails you meant.");
      if (!(await Gmail.modify(known, a.op))) return reply("Gmail didn't make that change.");
      const verb = { archive: "Archived", read: "Marked read:", unread: "Marked unread:", star: "Starred" }[a.op];
      return reply(`${verb} ${known.length} email${known.length === 1 ? "" : "s"}.`);
    }
  }
}

/// The inbox at chat open, when Gmail is connected; its ids go into `known`.
async function mailContextBlock(known: Set<string>): Promise<string> {
  if (!Gmail.isReady()) return "";
  try {
    const { unread, recent } = await Gmail.inbox();
    for (const m of [...unread, ...recent]) known.add(m.id);
    return MailIntent.contextBlock(unread, recent);
  } catch { return ""; }
}

/// A read of WhatsApp for the chat: who's waiting (unread), the recent chats,
/// and the thread on screen in full — best-effort, no chat switching, only when
/// WA is up and logged in. null when there's nothing.
async function waContextBlock(): Promise<string | null> {
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
      const lines = thread.slice(-14).map(m => `${m.outgoing ? "You" : who}: ${m.text}`);
      parts.push(`Open thread with ${who} (each line is labelled with who sent it):\n` + lines.join("\n"));
    }
    if (!parts.length) return null;
    return "### whatsapp\n" + parts.join("\n\n");
  } catch { return null; }
}

/// Beside the avatar on the side with room (right first), the field level with its bottom, kept in the work area.
/// flip: the box sits left of the avatar, so Nikxel's bubbles go on the right, next to it.
function place(avatar: Rectangle): { x: number; y: number; flip: boolean } {
  const wa = screen.getDisplayMatching(avatar).workArea;
  const right = wa.x + wa.width - (avatar.x + avatar.width), left = avatar.x - wa.x;
  const flip = right < W + gap && left > right;
  const x = Math.min(Math.max(flip ? avatar.x - gap - W : avatar.x + avatar.width + gap, wa.x), wa.x + wa.width - W);
  const y = Math.min(Math.max(avatar.y + avatar.height - H, wa.y), wa.y + wa.height - H);
  return { x: Math.round(x), y: Math.round(y), flip };
}

export function toggle(avatar: Rectangle, pinnedTo: BrowserWindow, agent: MOMGenerator, recording: () => boolean): void {
  if (current && !current.isDestroyed()) { current.close(); return; }

  const { x, y, flip } = place(avatar);
  const id = `c${++seq}`;
  const win = new BrowserWindow({
    x, y, width: W, height: H,
    frame: false,
    transparent: true,
    hasShadow: false,
    alwaysOnTop: true,
    resizable: false,
    minimizable: false,
    maximizable: false,
    skipTaskbar: true,
    show: false,
    webPreferences: { preload: preloadPath("avatarChat"), contextIsolation: true, nodeIntegration: false, sandbox: true },
  });
  current = win;
  const history: { q: string; a: string }[] = [];
  // Fetched once as the box opens, while the user types; every question reuses it.
  const feedP = CloudSync.projectFeed(CloudSync.getter(3000));
  const waP = waContextBlock(); // read WhatsApp once; every question reuses it
  const mail: MailState = { known: new Set(), lastDraftId: null };
  const mailP = mailContextBlock(mail.known);

  ipcMain.handle(`chat:send:${id}`, async (_e, text: string) => {
    const today = new Date();
    const { feed, offline } = await feedP;
    // What Nikxel has learned about the user goes first, then what it's doing right
    // now and has done today, then the WhatsApp read, then the written summaries.
    const live = DayLogger.current ? "### right now\n" + (await DayLogger.current.liveContextAsync(MeetingDetector.shared.isInMeeting)) : "";
    const wa = await waP;
    let context = [Settings.userContextBlock, live, wa ?? "", await mailP,
      build([...localBlocks(path.join(documentsRoot(), "nikxel"), today), ...projectBlocks(feed)], CAP)].filter(x => x).join("\n\n");
    // Mail: "send it", drafts and labels answer here; a search adds to the context.
    const m = await handleMail(text, context, history, today, agent, mail);
    if (m.kind === "reply") {
      history.push({ q: text, a: m.text });
      return { text: m.text, offline, error: false };
    }
    if (m.kind === "context") context += "\n\n" + m.text;
    // "make a task to …" creates one in ERP, drafted from the same
    // meeting/WhatsApp/project context, then opens it to review.
    if (ERP.looksLikeTaskRequest(text)) {
      const reply = await makeERPTask(text, context, today, agent);
      history.push({ q: text, a: reply });
      return { text: reply, offline, error: false };
    }
    let reply: string, error = false;
    try {
      reply = (await agent.runPrompt(prompt(context, history, text, today), "chat", "haiku", 30)).trim();
      history.push({ q: text, a: reply });
    } catch (e) {
      error = true;
      reply = e instanceof MOMError && e.kind === "agentNotFound" ? "Connect Claude in Settings to use chat." : "⚠︎ " + (e as Error).message;
    }
    cblog(`AvatarChat: ${context.length} chars of context`);
    return { text: reply, offline, error };
  });
  // 16 kHz mono 16-bit PCM from the page's mic, as whisper.cpp wants it.
  ipcMain.handle(`chat:voice:${id}`, async (_e, pcm: Uint8Array) => {
    const wav = nikxelPath("edits", "chat-voice.wav");
    writeAtomic(wav, Buffer.concat([wavHeader(pcm.byteLength, 16000, 1), Buffer.from(pcm)]));
    try { return (readText(await new Transcriber().transcribe(wav, "txt")) ?? "").trim(); } catch { return ""; }
  });
  ipcMain.handle(`chat:close:${id}`, () => { if (!win.isDestroyed()) win.close(); });
  // Follows Nikxel when it moves, re-placed each time so it stays on the side with room and in the work area.
  const start = pinnedTo.getBounds();
  const follow = () => {
    if (win.isDestroyed()) return;
    const b = pinnedTo.getBounds();
    const p = place({ ...avatar, x: avatar.x + b.x - start.x, y: avatar.y + b.y - start.y });
    win.setBounds({ x: p.x, y: p.y, width: W, height: H });
    void win.webContents.executeJavaScript(`document.body.classList.toggle("flip", ${p.flip})`);
  };
  pinnedTo.on("move", follow);
  // A clear window still swallows clicks, so it takes them only over the bubbles and field the page reports.
  let hits: number[][] = [], ignoring = false;
  ipcMain.on(`chat:hit:${id}`, (_e, rects: number[][]) => { hits = rects; });
  const hitTimer = setInterval(() => {
    if (win.isDestroyed()) return;
    const c = screen.getCursorScreenPoint(), b = win.getBounds(), px = c.x - b.x, py = c.y - b.y;
    const over = hits.some(([x, y, w, h]) => px >= x && px < x + w && py >= y && py < y + h);
    if (ignoring === over) { ignoring = !over; win.setIgnoreMouseEvents(ignoring); }
  }, 50);

  // A recording can start or stop while the box is open; the mic follows it.
  const timer = setInterval(() => { if (!win.isDestroyed()) win.webContents.send("chat:recording", recording()); }, 1000);
  win.on("closed", () => {
    clearInterval(timer);
    clearInterval(hitTimer);
    pinnedTo.removeListener("move", follow);
    ipcMain.removeAllListeners(`chat:hit:${id}`);
    for (const ch of ["send", "voice", "close"]) ipcMain.removeHandler(`chat:${ch}:${id}`);
    if (current === win) current = null;
  });
  win.once("ready-to-show", () => { win.show(); win.focus(); });
  win.loadFile(rendererPath("avatarChat"), { query: { id, rec: recording() ? "1" : "0", flip: flip ? "1" : "0" } });
}
