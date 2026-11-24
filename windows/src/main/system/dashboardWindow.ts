import { app, BrowserWindow, dialog, ipcMain, nativeImage, nativeTheme, session, shell, WebContentsView } from "electron";
import * as fs from "fs";
import * as path from "path";
import { cblog } from "../core/diag";
import { openUrl, revealFile, summaryOpener } from "../core/open";
import { appendLine, HOME, nikxelPath, preloadPath, readText, rendererPath, writeAtomic } from "../core/paths";
import {
  AGENT_INFO, CODING_AGENTS, CodingAgent, NOTE_FORMATS, NOTE_FORMAT_INFO, NoteFormat, Settings, WA_BOT_MODES,
  WA_BOT_MODE_NAMES, WABotMode,
} from "../core/settings";
import { GoogleAuth } from "../google/googleAuth";
import { MOMGenerator } from "../recording/momGenerator";
import { SummaryTemplates } from "../recording/summaryTemplates";
import { Transcriber } from "../recording/transcriber";
import { UsageLog, UsageTotals } from "../recording/usageLog";
import { wavHeader } from "../recording/wavWriter";
import { ChatbotEngine } from "../whatsapp/chatbotEngine";
import { ChromeWhatsApp } from "../whatsapp/chromeWhatsApp";
import { MeetingDetector } from "../whatsapp/meetingDetector";
import { WAContactLists } from "../whatsapp/waContactLists";
import * as Automation from "./automation";
import { Automations } from "./automations";
import { ChatSession } from "./chatSession";
import { CloudSync } from "./cloudSync";
import * as DashboardData from "./dashboardData";
import * as DayPage from "./dayPage";
import * as ERP from "./erp";
import * as Slack from "./slack";
import { spriteRows } from "./spriteFrames";
import * as SummaryLibrary from "./summaryLibrary";

/// Port of DashboardWindow.swift: the Nikxel window, every setting the tray
/// used to hold, the Library with summaries in tabs, Chat, Tasks, People,
/// Activity and Automations. The page is the Mac's own (see the preload); this
/// file draws nothing, it only sends `state()` and acts on what the page posts.
/// Controls go through the same handlers the tray did (DashboardHost), so the
/// tray, the running bot and this window never disagree.
///
/// Closing the window destroys it and every tab with it: each page is a
/// renderer, and a hidden window kept around costs memory all day.

/// What main.ts lends this window: the agent, the recorder, and the actions
/// that live there (connections, templates, updates…).
export interface DashboardHost {
  agent: MOMGenerator;
  isRecording(): boolean;
  recordingSince(): number;
  isMicMuted(): boolean;
  isAvatarVisible(): boolean;
  applyAvatarSize(): void;
  action(name: string): void;
}

let host: DashboardHost | null = null;
let win: BrowserWindow | null = null;
let pageLoaded = false;
let section = "home";
/// Summaries open in tabs, like files in an editor; `active` is the one shown,
/// null while a section is. Each tab keeps its own page (scroll, edits, chat).
interface Tab { file: string; view: WebContentsView }
let tabs: Tab[] = [];
let active: Tab | null = null;
/// The text file open in the page's editor (personality, a contact list, a template).
let editing: { file: string; title: string; help: string } | null = null;
/// The Chat section's conversation, the same engine as the avatar's chat.
let chat: ChatSession | null = null;
/// Today's calendar, fetched at most every few minutes as the window comes forward.
let events: Record<string, unknown>[] = [];
let eventsFetched = 0;

/// The tab bar the page draws above the open summary, and the sidebar beside it.
const BAR = 52;
const sideWidth = () => (Settings.dashboardSideCollapsed ? 76 : 248);

export function init(h: DashboardHost): void {
  host = h;
  // You → Appearance. Electron's theme is app-wide; the window's page (and
  // the summary tabs) read it through prefers-color-scheme.
  nativeTheme.themeSource = Settings.appearance;
  // core/open.ts's openFile asks here first, so every "open this summary"
  // (cards, notifications) lands in a tab unless the user chose the browser.
  summaryOpener.open = file => {
    if (!Settings.openSummariesInApp || !canRead(file)) return false;
    openSummary(file);
    return true;
  };
  Automations.onChange = push;
  Automations.onOpen = () => show("automations");
  ipcMain.on("dashboard:msg", (e, m) => { if (win && e.sender === win.webContents) handle(m); });
  ipcMain.on("dashboard:reply", (e, id: number, v: unknown) => { if (win && e.sender === win.webContents) reply(id, v); });
  ipcMain.handle("dashboard:recording", () => host?.isRecording() ?? false);
  // 16 kHz mono 16-bit PCM from the page's mic.
  ipcMain.handle("dashboard:voice", async (_e, pcm: Uint8Array) => {
    const wav = nikxelPath("edits", "chat-voice.wav");
    writeAtomic(wav, Buffer.concat([wavHeader(pcm.byteLength, 16000, 1), Buffer.from(pcm)]));
    try { return (readText(await new Transcriber().transcribe(wav, "txt")) ?? "").trim(); } catch { return ""; }
  });
  // The meeting's .ics ("Apple / Outlook") is a data: link with download: save
  // it to Downloads and open it, which hands it to Outlook or Calendar.
  session.defaultSession.on("will-download", (_e, item) => {
    const dir = app.getPath("downloads"), name = item.getFilename(), ext = path.extname(name), base = path.basename(name, ext);
    let dest = path.join(dir, name);
    for (let n = 2; fs.existsSync(dest); n++) dest = path.join(dir, `${base} ${n}${ext}`);
    item.setSavePath(dest);
    item.once("done", (_ev, state) => { if (state === "completed") void shell.openPath(dest); });
  });
}

/// A summary page the reader can show: an .html or .pdf under Documents/nikxel.
export function canRead(file: string): boolean {
  const root = path.resolve(SummaryLibrary.libraryRoot()) + path.sep;
  return /\.(html|pdf)$/i.test(file) && path.resolve(file).toLowerCase().startsWith(root.toLowerCase());
}

/// Shows the window, on `section` when given.
export function show(to?: string): void {
  if (to) { section = to; showSection(); }
  if (!win) create();
  else { if (win.isMinimized()) win.restore(); win.show(); win.focus(); }
  if (to && pageLoaded) void win?.webContents.executeJavaScript(`nx.go(${JSON.stringify(to)})`).catch(() => {});
}

/// Shows the window with `file` open in a tab.
export function openSummary(file: string): void {
  show();
  if (pageLoaded) read(file);
  else win?.webContents.once("did-finish-load", () => read(file));
}

function create(): void {
  pageLoaded = false;
  win = new BrowserWindow({
    width: 1120, height: 780, minWidth: 900, minHeight: 620, title: "Nikxel",
    // The page's paper, so nothing flashes white before it paints.
    backgroundColor: nativeTheme.shouldUseDarkColors ? "#151411" : "#f6f4ee", autoHideMenuBar: true, show: false,
    icon: nativeImage.createFromPath(path.join(__dirname, "..", "..", "..", "resources", "icon.png")),
    webPreferences: { preload: preloadPath("dashboard"), contextIsolation: true, nodeIntegration: false },
  });
  win.once("ready-to-show", () => win?.show());
  win.on("focus", push);   // back from the browser or another app: connections may have changed
  win.on("resize", layout);
  win.on("closed", () => {
    for (const t of tabs) t.view.webContents.close();
    tabs = []; active = null; editing = null; chat = null; win = null; pageLoaded = false;
  });
  // Links in the page itself never navigate it away.
  win.webContents.setWindowOpenHandler(({ url }) => { openUrl(url); return { action: "deny" }; });
  win.webContents.on("will-navigate", e => e.preventDefault());
  win.webContents.on("did-finish-load", () => {
    pageLoaded = true;
    const clouds = path.join(path.dirname(rendererPath("dashboard")), "clouds.png").replace(/\\/g, "/");
    void win?.webContents.executeJavaScript(
      `document.documentElement.style.setProperty('--clouds', ${JSON.stringify(`url("file:///${clouds.replace(/^\//, "")}")`)});` +
      `nx.frames(${JSON.stringify(spriteRows())})`).catch(() => {});
    push();
  });
  void win.loadFile(rendererPath("dashboard"));
}

function push(): void {
  if (!win || !pageLoaded) return;
  void win.webContents.executeJavaScript(`nx.state(${JSON.stringify(state())})`).catch(e => cblog(`Dashboard: push failed — ${e}`));
}

function reply(id: number, value: unknown): void {
  void win?.webContents.executeJavaScript(`nx.reply(${id}, ${JSON.stringify([value])}[0])`).catch(() => {});
}

// MARK: - Page bridge

function handle(m: Record<string, any>): void {   // eslint-disable-line @typescript-eslint/no-explicit-any
  switch (m.type) {
    case "section": section = String(m.id ?? "home"); break;
    case "set": set(String(m.key), m.value); push(); break;
    case "action":
      run(String(m.name));
      // Most actions open something or change a connection; give it a
      // moment, then show where things stand.
      setTimeout(push, 800);
      break;
    case "open": open(String(m.id)); break;
    case "tab": { const t = tabs.find(x => x.file === m.id); if (t) activate(t); break; }
    case "closeTab": closeTab(String(m.id)); push(); break;
    case "side": Settings.dashboardSideCollapsed = !!m.collapsed; layout(); break;
    case "chatStart": startChat(); break;
    case "chat": {
      startChat();
      const id = m.id;
      void chat?.send(String(m.text ?? "")).then(r => reply(id, r));
      break;
    }
    case "chatNew": chat = null; startChat(); break;
    case "task":
      if (typeof m.md === "string" && typeof m.n === "number") tickItem(m.md, m.n, !!m.done);
      push();
      break;
    case "dayTask":
      if (typeof m.id === "string" && typeof m.i === "number") DayPage.tick(m.id, m.i, true);
      push();
      break;
    case "search": {
      const q = String(m.q ?? "");
      const files = SummaryLibrary.scan().map(e => ({ id: e.file, md: mdOf(e.file) }));
      const found = DashboardData.search(q, files);
      void win?.webContents.executeJavaScript(`nx.found(${JSON.stringify(q)}, ${JSON.stringify(found)})`).catch(() => {});
      break;
    }
    case "neverReply": {
      const name = String(m.name ?? "").trim();
      if (name && !WAContactLists.contains("neverReply", name)) appendLine(WAContactLists.seedIfMissing("neverReply"), name);
      push();
      break;
    }
    case "openChat":
      ChromeWhatsApp.activate();
      void ChromeWhatsApp.openChatBySearch(String(m.name ?? ""));
      break;
    case "openURL": if (/^https:\/\//.test(String(m.url))) openUrl(String(m.url)); break;
    case "saveFile":
      if (editing && typeof m.text === "string") writeAtomic(editing.file, m.text);
      editing = null; push();
      break;
    case "closeFile": editing = null; push(); break;
    case "autoSave": {
      const d = m.a ?? {};
      const clean = Automation.clean({ id: d.id ?? "", name: d.name ?? "", trigger: d.trigger ?? "", time: d.time ?? "09:00",
        days: d.days ?? "daily", instruction: d.instruction ?? "", enabled: true, lastRun: "" });
      if (!clean) return;
      const list = Automation.load(), i = list.findIndex(a => a.id === clean.id);
      if (i >= 0) list[i] = { ...clean, enabled: list[i].enabled, lastRun: list[i].lastRun }; else list.push(clean);
      Automation.save(list); push();
      break;
    }
    case "autoToggle": {
      const list = Automation.load(), a = list.find(x => x.id === m.id);
      if (a) { a.enabled = m.on !== false; Automation.save(list); }
      push();
      break;
    }
    case "autoDelete": Automation.save(Automation.load().filter(a => a.id !== m.id)); push(); break;
    case "autoRun": { const a = Automation.load().find(x => x.id === m.id); if (a) Automations.runNow(a); break; }
    case "autoMake": {
      const id = m.id;
      void Automations.make(String(m.text ?? "")).then(a => reply(id, a ? Automation.dict(a)
        : { error: "I couldn't turn that into an automation. Try saying when it should run and what I should do." }));
      break;
    }
    case "autoSuggest": {
      const id = m.id;
      void Automations.suggest().then(list => reply(id, list.map(x => ({ ...Automation.dict(x.a), why: x.why }))));
      break;
    }
  }
}

function startChat(): void {
  if (chat || !host) return;
  const session = new ChatSession(host.agent);
  chat = session;
  // What it can see takes the start-up reads (WhatsApp, mail, the team feed).
  void session.sources().then(sources => {
    if (chat !== session || !win) return;
    void win.webContents.executeJavaScript(`nx.sources(${JSON.stringify(sources)})`).catch(() => {});
  });
}

// MARK: - Settings

function set(key: string, value: unknown): void {
  const on = value === true;
  const text = typeof value === "string" ? value.trim() : "";
  const num = typeof value === "number" ? value : Number(text) || 0;
  switch (key) {
    case "botEnabled": ChatbotEngine.shared.isEnabled = on; break;
    case "waGroupReplies": Settings.waGroupReplies = on; break;
    case "waDraftOnly": Settings.waDraftOnly = on; break;
    case "waQuietHours": Settings.waQuietHours = on; break;
    case "waWorkContext": Settings.waWorkContext = on; break;
    case "waChatTasks": Settings.waChatTasks = on; break;
    case "googleSyncEnabled": Settings.googleSyncEnabled = on; break;
    case "forceMeeting": MeetingDetector.shared.manualOverride = on; break;
    case "autoRecordCalls": Settings.autoRecordCalls = on; break;
    case "openInApp": Settings.openSummariesInApp = on; break;
    case "appearance":
      Settings.appearance = text === "light" || text === "dark" ? text : "system";
      nativeTheme.themeSource = Settings.appearance;
      break;
    case "waBotMode":
      if ((WA_BOT_MODES as string[]).includes(text)) { Settings.waBotMode = text as WABotMode; ChatbotEngine.shared.applyModeChange(); }
      break;
    case "captureMode": Settings.captureMode = text === "notes" ? "notes" : "meeting"; break;
    case "noteFormat": if ((NOTE_FORMATS as string[]).includes(text)) Settings.noteFormat = text as NoteFormat; break;
    case "avatarSize": Settings.avatarSize = num || 1; host?.applyAvatarSize(); break;
    case "summaryTemplate": Settings.summaryTemplate = text; break;
    case "agent": if ((CODING_AGENTS as string[]).includes(text)) Settings.connectedAgent = text as CodingAgent; break;
    case "language": Settings.language = text || "auto"; break;
    case "transcriptionLanguage": Settings.transcriptionLanguage = text; break;
    case "summaryMinutes": Settings.summaryMinutes = num; break;
    case "botMemoryDays": Settings.botMemoryDays = num; break;
    case "waUnattendedMinutes": Settings.waUnattendedMinutes = Math.max(1, Math.min(120, num)); break;
    case "waQuietFrom": Settings.waQuietFrom = num; break;
    case "waQuietTo": Settings.waQuietTo = num; break;
    case "userName": if (text) Settings.userName = text; break;
    case "waOwnName": Settings.waOwnName = text; break;
    case "userContext": Settings.userContext = text; break;
  }
}

function run(name: string): void {
  switch (name) {
    case "editTemplate":
      return edit(SummaryTemplates.activeURL, `“${SummaryTemplates.displayName(Settings.summaryTemplate)}” template`,
        "Plain instructions, one per line, the way you’d tell a person: drop a section, add one, change the order, the length or the tone. Lines starting with # are ignored. Takes effect on your next recording; names, decisions and numbers still come only from the transcript.");
    case "editPersonality":
      return edit(personalityFile(), "How I sound on WhatsApp", "The voice and rules I reply with. Write it the way you’d brief an assistant.");
    case "editTrusted":
      return edit(WAContactLists.seedIfMissing("trusted"), "Trusted contacts", "One name per line, as it shows in WhatsApp. I can say more to these people. Lines starting with # are ignored.");
    case "editNeverReply":
      return edit(WAContactLists.seedIfMissing("neverReply"), "Never reply to", "One name per line, as it shows in WhatsApp. I always leave these chats to you. Lines starting with # are ignored.");
    case "chooseProjects": return void chooseProjectsFolder();
    case "closeSummary": showSection(); return push();
    case "openInBrowser": if (active) void shell.openPath(active.file); return;
    case "revealSummary": if (active) revealFile(active.file); return;
    default: host?.action(name);
  }
}

function edit(file: string, title: string, help: string): void {
  editing = { file, title, help };
  push();
}

/// ~/.nikxel/bot_personality.txt, written with the default first if missing.
export function personalityFile(): string {
  const file = nikxelPath("bot_personality.txt");
  if (!fs.existsSync(file)) {
    const name = Settings.userName;
    writeAtomic(file, `You are ${name}'s friendly AI assistant. You're responding to WhatsApp messages while ${name} is in a meeting. Be casual, warm, and helpful. Keep responses concise (1-3 sentences). Be honest -- say you're ${name}'s assistant, don't pretend to be them.\n`);
  }
  return file;
}

async function chooseProjectsFolder(): Promise<void> {
  if (!win) return;
  const r = await dialog.showOpenDialog(win, {
    properties: ["openDirectory"], defaultPath: Settings.projectsRoot, message: "Pick the folder your git projects live in",
  });
  if (!r.canceled && r.filePaths[0]) { Settings.projectsRoot = r.filePaths[0]; push(); }
}

// MARK: - Tasks, people, today

const mdOf = (file: string) => file.replace(/\.[^.\\/]+$/, ".md");

/// The .md beside the page, and the page's box with it.
function tickItem(md: string, n: number, done: boolean): void {
  const text = readText(md);
  const updated = text === null ? null : DashboardData.markItem(text, n, done);
  if (updated === null) return;
  writeAtomic(md, updated);
  const page = md.replace(/\.md$/, ".html"), html = readText(page);
  if (html !== null) writeAtomic(page, html.replace(new RegExp(`id="task-${n}"( checked)?`), `id="task-${n}"` + (done ? " checked" : "")));
}

/// Today: the calendar (refetched now and then), the latest day page's open tasks.
function today(library: SummaryLibrary.LibraryEntry[]): Record<string, unknown> {
  const google = GoogleAuth.shared.isAuthorized;
  if (google && Date.now() - eventsFetched > 300_000) { eventsFetched = Date.now(); void fetchEvents(); }
  const out: Record<string, unknown> = { events, google };
  const day = library.find(e => e.kind === "daily" && e.file.endsWith(".html"));
  const md = day ? readText(mdOf(day.file)) : null;
  if (day && md !== null) {
    out.dayId = day.file;
    out.dayDate = day.date;
    out.openTasks = DayPage.openTasksIndexed(md);
  }
  return out;
}

async function fetchEvents(): Promise<void> {
  try {
    const token = await GoogleAuth.shared.getAccessToken();
    const now = new Date(), end = new Date(now); end.setHours(23, 59, 59, 999);
    const q = new URLSearchParams({ timeMin: new Date(now.getTime() - 1_800_000).toISOString(), timeMax: end.toISOString(),
      singleEvents: "true", orderBy: "startTime", maxResults: "12" });
    const res = await fetch(`https://www.googleapis.com/calendar/v3/calendars/primary/events?${q}`, { headers: { Authorization: `Bearer ${token}` } });
    const obj = await res.json() as { items?: any[] };   // eslint-disable-line @typescript-eslint/no-explicit-any
    events = (obj.items ?? []).flatMap(item => {
      const s = item.start?.dateTime;   // all-day events aren't meetings
      if (!s) return [];
      const start = new Date(s).getTime() / 1000, end2 = item.end?.dateTime ? new Date(item.end.dateTime).getTime() / 1000 : start;
      return [{ title: item.summary ?? "Meeting", start, end: end2, link: item.hangoutLink ?? "" }];
    });
    push();
  } catch { /* not connected, offline: no calendar on Home */ }
}

/// Cost and calls per day for the last 14 days, oldest first.
function usageDays(): { day: string; cost: number; calls: number }[] {
  const out = [];
  for (let back = 13; back >= 0; back--) {
    const d = new Date(); d.setDate(d.getDate() - back);
    const t = Object.values(UsageLog.totals(d));
    out.push({ day: dayKey(d), cost: t.reduce((a, x) => a + x.cost, 0), calls: t.reduce((a, x) => a + x.calls, 0) });
  }
  return out;
}

const dayKey = (d: Date) => `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`;

// MARK: - Tabs

/// A library row: pages and PDFs in a tab, .md and .docx in their own app.
function open(file: string): void {
  if (canRead(file)) read(file); else void shell.openPath(file);
}

function read(file: string): void {
  const open = tabs.find(t => path.resolve(t.file) === path.resolve(file));
  if (open) return activate(open);
  const view = new WebContentsView({ webPreferences: { contextIsolation: true, nodeIntegration: false } });
  view.setBackgroundColor("#f6f4ee");
  const tab: Tab = { file, view };
  const wc = view.webContents;
  wc.on("page-title-updated", push);
  // window.open: a summary page (the client view) opens in a tab, anything else in the browser.
  wc.setWindowOpenHandler(({ url }) => {
    const target = fileOf(url);
    if (target && canRead(target)) setImmediate(() => read(target)); else openUrl(url);
    return { action: "deny" };
  });
  // Same page, or location.replace after a rename: stays in this tab. Links out: the browser.
  wc.on("will-navigate", (e, url) => {
    const target = fileOf(url);
    if (target && canRead(target)) return;
    if (url.startsWith("data:")) return;   // the .ics download
    e.preventDefault();
    openUrl(url);
  });
  wc.on("did-navigate", (_e, url) => { const target = fileOf(url); if (target) { tab.file = target; push(); } });
  void wc.loadFile(file);
  tabs.push(tab);
  activate(tab);
}

const fileOf = (url: string): string | null => {
  if (!url.startsWith("file:")) return null;
  try { return decodeURIComponent(new URL(url).pathname).replace(/^\/([A-Za-z]:)/, "$1"); } catch { return null; }
};

function activate(tab: Tab): void {
  if (!win) return;
  active = tab;
  for (const t of tabs) if (t !== tab) win.contentView.removeChildView(t.view);
  win.contentView.addChildView(tab.view);
  layout();
  push();
}

/// Back to the section; the tabs stay open.
function showSection(): void {
  if (win && active) win.contentView.removeChildView(active.view);
  active = null;
}

function closeTab(file: string): void {
  const i = tabs.findIndex(t => t.file === file);
  if (i < 0) return;
  const [tab] = tabs.splice(i, 1);
  win?.contentView.removeChildView(tab.view);
  tab.view.webContents.close();
  if (tab === active) { if (tabs.length) activate(tabs[Math.min(i, tabs.length - 1)]); else showSection(); }
}

/// The open summary fills the main column under the tab bar.
function layout(): void {
  if (!win || !active) return;
  const [w, h] = win.getContentSize(), x = sideWidth();
  active.view.setBounds({ x, y: BAR, width: Math.max(0, w - x), height: Math.max(0, h - BAR) });
}

// MARK: - State

function state(): Record<string, unknown> {
  const library = SummaryLibrary.scan();
  const { tasks, people } = DashboardData.tasksAndPeople(library, [Settings.userName, Settings.waOwnName]);
  const today0 = UsageLog.totals(new Date());
  const all: UsageTotals = { calls: 0, tokens: 0, cost: 0 };
  for (const t of Object.values(today0)) { all.calls += t.calls; all.tokens += t.tokens; all.cost += t.cost; }
  const { avg, days } = UsageLog.dailyAverage();
  const waLogs = path.join(process.env.APPDATA ?? path.join(HOME, "AppData", "Roaming"), "Nikxel", "whatsapp");
  const google = GoogleAuth.shared.isAuthorized;
  return {
    platform: "win",
    section,
    hour: new Date().getHours(),
    name: Settings.userName,
    waOwnName: Settings.waOwnName,
    userContext: Settings.userContext,
    language: Settings.language,
    transcriptionLanguage: Settings.transcriptionLanguage,
    avatarSize: Settings.avatarSize,
    agent: Settings.connectedAgent,
    agents: CODING_AGENTS.map(id => ({ id, name: AGENT_INFO[id].displayName })),
    captureMode: Settings.captureMode,
    noteFormat: Settings.noteFormat,
    noteFormats: NOTE_FORMATS.map(id => ({ id, name: NOTE_FORMAT_INFO[id].displayName })),
    autoRecordCalls: Settings.autoRecordCalls,
    forceMeeting: MeetingDetector.shared.manualOverride,
    summaryMinutes: Settings.summaryMinutes,
    summaryTemplate: Settings.summaryTemplate,
    templates: SummaryTemplates.available().map(t => ({ id: t.slug, name: t.name })),
    googleSyncEnabled: Settings.googleSyncEnabled,
    botEnabled: ChatbotEngine.shared.isEnabled,
    waBotMode: Settings.waBotMode,
    waModes: WA_BOT_MODES.map(id => ({ id, name: WA_BOT_MODE_NAMES[id] })),
    waUnattendedMinutes: Settings.waUnattendedMinutes,
    waGroupReplies: Settings.waGroupReplies,
    waDraftOnly: Settings.waDraftOnly,
    waQuietHours: Settings.waQuietHours,
    waQuietFrom: Settings.waQuietFrom,
    waQuietTo: Settings.waQuietTo,
    waWorkContext: Settings.waWorkContext,
    waChatTasks: Settings.waChatTasks,
    botMemoryDays: Settings.botMemoryDays,
    projectsRoot: Settings.projectsRoot.replace(HOME, "~"),
    status: {
      whatsapp: Settings.whatsappConnected,
      google,
      slack: Slack.isConnected(),
      // No Apple Reminders on Windows: new Google Tasks bubble up instead.
      reminders: google,
      dashboard: CloudSync.token() !== null,
      erp: ERP.isConnected(),
    },
    usageToday: UsageLog.line(all),
    usageAverage: days === 0 ? "" : UsageLog.line(avg),
    library: library.map(SummaryLibrary.entryDict),
    tabs: tabs.map(t => {
      const e = library.find(x => path.resolve(x.file) === path.resolve(t.file));
      return { id: t.file, title: e?.title ?? (t.view.webContents.getTitle() || path.basename(t.file, path.extname(t.file))), date: e?.date ?? "", kind: e?.kind ?? "" };
    }),
    active: active?.file ?? null,
    sideCollapsed: Settings.dashboardSideCollapsed,
    recording: host?.isRecording() ?? false,
    micMuted: host?.isMicMuted() ?? false,
    visible: host?.isAvatarVisible() ?? false,
    templateShipped: SummaryTemplates.isShipped(Settings.summaryTemplate),
    openInApp: Settings.openSummariesInApp,
    appearance: Settings.appearance,
    editor: editing ? { title: editing.title, help: editing.help, text: readText(editing.file) ?? "" } : null,
    tasks,
    people,
    today: today(library),
    recordingSince: host?.recordingSince() ?? 0,
    captureLabel: Settings.captureMode === "notes" ? "Notes" : "Meeting",
    botReplies: DashboardData.botReplies(new Date(), waLogs),
    neverReply: WAContactLists.names("neverReply"),
    usageDays: usageDays(),
    automations: Automation.load().map(Automation.dict),
    automationRuns: Automations.runs,
    automationRunning: Automations.running ?? "",
    ideas: Automation.IDEAS.map(Automation.dict),
  };
}

