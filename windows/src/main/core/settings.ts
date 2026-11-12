import * as fs from "fs";
import * as os from "os";
import { nikxelPath, expandTilde, HOME, resourcePath, writeAtomic, readText } from "./paths";
import * as path from "path";

/// Port of NikxelSettings.swift. Backed by ~/.nikxel/settings.json — the same
/// file and keys as the Mac app, so it stays easy to open and edit by hand.

export type CodingAgent = "claude" | "opencode" | "codex";
export const CODING_AGENTS: CodingAgent[] = ["claude", "opencode", "codex"];

export const AGENT_INFO: Record<CodingAgent, { displayName: string; installCommand: string; processNames: string[] }> = {
  claude: {
    displayName: "Claude Code",
    installCommand: "npm install -g @anthropic-ai/claude-code",
    processNames: ["claude", "claude-code"],
  },
  opencode: {
    displayName: "OpenCode",
    installCommand: "npm install -g opencode-ai",
    processNames: ["opencode"],
  },
  codex: {
    displayName: "Codex",
    installCommand: "npm install -g @openai/codex",
    processNames: ["codex"],
  },
};

/// When the WhatsApp bot may answer on the user's behalf. See WABotMode in
/// NikxelSettings.swift for the reasoning behind each.
export type WABotMode = "meetings" | "unattended" | "always";
export const WA_BOT_MODES: WABotMode[] = ["meetings", "unattended", "always"];
export const WA_BOT_MODE_NAMES: Record<WABotMode, string> = {
  meetings: "Only during meetings",
  unattended: "Any time, if unanswered for a while",
  always: "Any time, immediately",
};

export type NoteFormat = "page" | "markdown" | "pdf" | "word";
export const NOTE_FORMATS: NoteFormat[] = ["page", "markdown", "pdf", "word"];
export const NOTE_FORMAT_INFO: Record<NoteFormat, { displayName: string; ext: string }> = {
  page: { displayName: "Page (.html)", ext: "html" },
  markdown: { displayName: "Markdown (.md)", ext: "md" },
  pdf: { displayName: "PDF (.pdf)", ext: "pdf" },
  word: { displayName: "Word (.docx)", ext: "docx" },
};

export type CaptureMode = "notes" | "meeting";
export const CAPTURE_MODE_NAMES: Record<CaptureMode, string> = { notes: "Notes", meeting: "Meeting" };

interface Stored {
  userName?: string;
  language?: string;
  waOwnName?: string;
  transcriptionLanguage?: string;
  noteFormat?: string;
  connectedAgent?: string;
  whatsappConnected?: boolean;
  onboardingCompleted?: boolean;
  botMemoryDays?: number;
  googleSyncEnabled?: boolean;
  summaryTemplate?: string;
  waBotMode?: string;
  waGroupReplies?: boolean;
  waUnattendedMinutes?: number;
  waWorkContext?: boolean;
  waDraftOnly?: boolean;
  waQuietHours?: boolean;
  waQuietFrom?: number;
  waQuietTo?: number;
  waChatTasks?: boolean;
  projectsRoot?: string;
  avatarSize?: number;
  loginItemOffered?: boolean;
  /// Mac stores these two in UserDefaults; Windows keeps them here.
  captureMode?: string;
  botEnabled?: boolean;
  /// Mac: UserDefaults "nikxel.micMuted". Recording keeps a silent mic track.
  micMuted?: boolean;
  /// Any key this version doesn't know is kept on save.
  [k: string]: unknown;
}

export const SETTINGS_FILE = nikxelPath("settings.json");

function load(): Stored {
  try {
    const obj = JSON.parse(fs.readFileSync(SETTINGS_FILE, "utf8"));
    return obj && typeof obj === "object" ? obj : {};
  } catch { return {}; }
}

function save(mutate: (s: Stored) => void): void {
  const s = load();
  mutate(s);
  try { writeAtomic(SETTINGS_FILE, JSON.stringify(s, null, 2)); } catch { /* read-only home: settings just don't stick */ }
}

const clamp = (v: number, lo: number, hi: number) => Math.max(lo, Math.min(hi, v));
const trimmed = (v: unknown) => (typeof v === "string" ? v.trim() : "");

/// First word of the account's full name ("Prince Choudhary" -> "Prince"), or
/// null when it's a bare login like "admin" or an email.
export function firstName(fullName: string, account: string): string | null {
  const full = fullName.trim();
  const first = full.split(/\s+/)[0] ?? "";
  if (first.length <= 1) return null;
  if (!/^\p{L}+$/u.test(first)) return null;
  if (!full.includes(" ") && first.toLowerCase() === account.toLowerCase()) return null;
  return first[0].toUpperCase() + first.slice(1);
}

/// Windows has no cheap API for the display name; USERNAME is the login, which
/// firstName() rejects unless it reads like a real name.
function accountFirstName(): string | null {
  const account = os.userInfo().username;
  return firstName(process.env.NIKXEL_FULL_NAME || account, account);
}

export const Settings = {
  get userName(): string {
    const raw = trimmed(load().userName);
    return raw || accountFirstName() || "Me";
  },
  set userName(v: string) { save(s => { s.userName = v; }); },

  get hasUserName(): boolean { return trimmed(load().userName) !== ""; },

  get waOwnName(): string { return trimmed(load().waOwnName) || Settings.userName; },
  set waOwnName(v: string) { save(s => { s.waOwnName = v; }); },

  get language(): string { return trimmed(load().language) || "auto"; },
  set language(v: string) { save(s => { s.language = v; }); },

  get languageInstruction(): string {
    const language = Settings.language;
    if (language.toLowerCase() === "auto") {
      return "The source content may be in English, Hindi, Hinglish (mixed), or any other language. Write your output in that SAME language — don't translate to English unless the source itself is already in English. For Hindi, always write it in Latin letters as Hinglish (e.g. \"kal meeting mein discuss karenge\") — never in Devanagari script. The transcript romanizes Hindi phonetically, so English and technical words may arrive misspelled (\"pheetchhar\", \"diployo\", \"shedyol\"); restore their normal English spelling (feature, deploy, schedule).";
    }
    return `Always write your output in ${language}, regardless of what language the source content is in. Translate as needed. If that language is Hindi, write it in Latin letters as Hinglish — never in Devanagari script.`;
  },

  /// Spoken language passed to whisper: "en", "hi", or "auto". Deliberately not
  /// "auto" by default — see NikxelSettings.swift.
  get transcriptionLanguage(): string { return trimmed(load().transcriptionLanguage) || "en"; },
  set transcriptionLanguage(v: string) { save(s => { s.transcriptionLanguage = v; }); },

  get botMemoryDays(): number { return clamp(load().botMemoryDays ?? 7, 0, 14); },
  set botMemoryDays(v: number) { save(s => { s.botMemoryDays = clamp(v, 0, 14); }); },

  get googleSyncEnabled(): boolean { return load().googleSyncEnabled ?? true; },
  set googleSyncEnabled(v: boolean) { save(s => { s.googleSyncEnabled = v; }); },

  get waBotMode(): WABotMode {
    const m = load().waBotMode as WABotMode;
    return WA_BOT_MODES.includes(m) ? m : "meetings";
  },
  set waBotMode(v: WABotMode) { save(s => { s.waBotMode = v; }); },

  get waGroupReplies(): boolean { return load().waGroupReplies ?? false; },
  set waGroupReplies(v: boolean) { save(s => { s.waGroupReplies = v; }); },

  get waUnattendedMinutes(): number { return clamp(load().waUnattendedMinutes ?? 5, 1, 120); },
  set waUnattendedMinutes(v: number) { save(s => { s.waUnattendedMinutes = clamp(v, 1, 120); }); },

  get waWorkContext(): boolean { return load().waWorkContext ?? true; },
  set waWorkContext(v: boolean) { save(s => { s.waWorkContext = v; }); },

  get waDraftOnly(): boolean { return load().waDraftOnly ?? false; },
  set waDraftOnly(v: boolean) { save(s => { s.waDraftOnly = v; }); },

  get waQuietHours(): boolean { return load().waQuietHours ?? true; },
  set waQuietHours(v: boolean) { save(s => { s.waQuietHours = v; }); },

  get waQuietFrom(): number { return clamp(load().waQuietFrom ?? 22, 0, 23); },
  set waQuietFrom(v: number) { save(s => { s.waQuietFrom = clamp(v, 0, 23); }); },

  get waQuietTo(): number { return clamp(load().waQuietTo ?? 8, 0, 23); },
  set waQuietTo(v: number) { save(s => { s.waQuietTo = clamp(v, 0, 23); }); },

  get waChatTasks(): boolean { return load().waChatTasks ?? true; },
  set waChatTasks(v: boolean) { save(s => { s.waChatTasks = v; }); },

  /// On-screen avatar size, 1 = the original 156 px.
  get avatarSize(): number { return clamp(load().avatarSize ?? 1, 0.4, 1.5); },
  set avatarSize(v: number) { save(s => { s.avatarSize = clamp(v, 0.4, 1.5); }); },

  get loginItemOffered(): boolean { return load().loginItemOffered ?? false; },
  set loginItemOffered(v: boolean) { save(s => { s.loginItemOffered = v; }); },

  /// Folder scanned for git repos for the day report and the bot's context.
  get projectsRoot(): string {
    const raw = trimmed(load().projectsRoot);
    return raw ? expandTilde(raw) : path.join(HOME, "Desktop");
  },
  set projectsRoot(v: string) { save(s => { s.projectsRoot = v; }); },

  /// Slug of the active file in ~/.nikxel/templates/. See summaryTemplates.ts.
  get summaryTemplate(): string { return trimmed(load().summaryTemplate) || "default"; },
  set summaryTemplate(v: string) { save(s => { s.summaryTemplate = v; }); },

  get noteFormat(): NoteFormat {
    const f = load().noteFormat as NoteFormat;
    return NOTE_FORMATS.includes(f) ? f : "page";
  },
  set noteFormat(v: NoteFormat) { save(s => { s.noteFormat = v; }); },

  get connectedAgent(): CodingAgent {
    const a = load().connectedAgent as CodingAgent;
    return CODING_AGENTS.includes(a) ? a : "claude";
  },
  set connectedAgent(v: CodingAgent) { save(s => { s.connectedAgent = v; }); },

  get whatsappConnected(): boolean { return load().whatsappConnected ?? false; },
  set whatsappConnected(v: boolean) { save(s => { s.whatsappConnected = v; }); },

  get onboardingCompleted(): boolean { return load().onboardingCompleted ?? false; },
  set onboardingCompleted(v: boolean) { save(s => { s.onboardingCompleted = v; }); },

  get captureMode(): CaptureMode { return load().captureMode === "meeting" ? "meeting" : "notes"; },
  set captureMode(v: CaptureMode) { save(s => { s.captureMode = v; }); },

  /// WhatsApp auto-replies master switch (ChatbotEngine.isEnabled).
  get botEnabled(): boolean { return load().botEnabled ?? true; },
  set botEnabled(v: boolean) { save(s => { s.botEnabled = v; }); },

  /// Mic mute (AudioRecorder.isMicMuted): recording continues, the mic track is silent.
  get micMuted(): boolean { return load().micMuted ?? false; },
  set micMuted(v: boolean) { save(s => { s.micMuted = v; }); },
};

/// Where the avatar's sprite sheet comes from: ~/.nikxel/sprites.png when the
/// user made their own, else the bundled sheet.
export const Sprites = {
  frameSize: 64,
  cols: 4,
  rows: 10,
  customPath: nikxelPath("sprites.png"),
  hasCustom(): boolean {
    try { fs.accessSync(Sprites.customPath, fs.constants.R_OK); return true; } catch { return false; }
  },
  activePath(): string {
    return Sprites.hasCustom() ? Sprites.customPath : resourcePath("sprites.png");
  },
};

export { readText };
