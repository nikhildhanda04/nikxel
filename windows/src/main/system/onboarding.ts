import * as fs from "fs";
import * as path from "path";
import { BrowserWindow, clipboard, dialog, ipcMain, nativeImage, IpcMainEvent } from "electron";
import { preloadPath, rendererPath, resourcePath, readText } from "../core/paths";
import { Settings, Sprites, CODING_AGENTS, AGENT_INFO, CodingAgent } from "../core/settings";
import { bus } from "../core/bus";
import { diag } from "../core/diag";
import type { MOMGenerator, AgentHealth } from "../recording/momGenerator";
import { Transcriber, ffmpegPath, hasModel, modelPath, downloadModel, installWhisper } from "../recording/transcriber";
import { ChromeWhatsApp } from "../whatsapp/chromeWhatsApp";
import { GoogleAuth } from "../google/googleAuth";
import { SpriteSheetImporter } from "./spriteSheetImporter";

/// First-run (and reopenable-anytime, via the tray) setup wizard: pick an
/// avatar, check the transcription tools, connect WhatsApp, and choose which
/// coding agent Nikxel should shell out to. Port of OnboardingWindow.swift.
///
/// The state lives here in the main process and the page is only a view of
/// it: closing the window throws the page away, but "Setup Wizard…" reopens
/// on the same step with everything as it was, like the Mac's window that
/// was hidden rather than released.

type Step = "welcome" | "avatar" | "deps" | "whatsapp" | "google" | "agent";
const STEPS: Step[] = ["welcome", "avatar", "deps", "whatsapp", "google", "agent"];
type Tone = "secondary" | "red" | "orange" | "green";

/// What the page renders. Mirrored by the interface in renderer/onboarding.ts.
export interface OnboardingView {
  step: Step;
  name: string;
  sprites: { cols: number; rows: number; frameSize: number };
  avatar: { frames: string[]; usingCustom: boolean; sheetError: string | null; promptCopied: boolean; importing: boolean };
  deps: {
    whisperFound: boolean; ffmpegFound: boolean; depsChecked: boolean;
    usingWhisperCpp: boolean; modelInstalled: boolean; modelName: string; modelSize: string;
    modelDownloading: boolean; modelProgress: number; modelError: string | null;
    installing: boolean; installMessage: string; installProgress: number | null; installError: string | null;
    language: string; languageOptions: { title: string; code: string }[];
  };
  whatsapp: { connecting: boolean; connected: boolean; launchFailed: string | null };
  google: { connected: boolean; oneClick: boolean };
  agents: { id: CodingAgent; name: string; status: string; tone: Tone; hint: string | null; copied: boolean; enabled: boolean; chosen: boolean }[];
  agentsTesting: boolean;
}

export type OnboardingAction =
  | { type: "ready" }
  | { type: "go"; step: Step }
  | { type: "welcomeNext"; name: string }
  | { type: "copyPrompt" } | { type: "chooseSheet" } | { type: "resetSheet" }
  | { type: "installDeps" } | { type: "recheckDeps" } | { type: "downloadModel" } | { type: "pickLanguage"; code: string }
  | { type: "waConnect" }
  | { type: "googleConnect" }
  | { type: "pickAgent"; agent: CodingAgent } | { type: "copyInstall"; agent: CodingAgent } | { type: "recheckAgents" }
  | { type: "finish" };

/// "en" handles all three cases and is what almost everyone should use.
/// Measured on the small model: English stays clean, Hindi comes back as
/// natural Hinglish with English words spelled properly ("Namaste, mai kal
/// meeting me shamil nahi ho paunga"), and Hinglish resolves to English.
/// Picking "hi" makes pure English come out as Devanagari gibberish, and
/// auto-detect reads Indian-accented English as Hindi.
const LANGUAGE_OPTIONS = [
  { title: "English — handles Hindi and Hinglish too (recommended)", code: "en" },
  { title: "Hindi — only for heavy Hindi; breaks pure English", code: "hi" },
  { title: "Auto-detect — not recommended, misreads Indian English as Hindi", code: "auto" },
];

const MODEL_DOWNLOAD_SIZE = "466 MB";

/// What a failed agent check says when the fix is to sign in. Same list
/// MOMGenerator.checkAgent sorted failures with on the Mac.
const AUTH_HINTS = ["not logged in", "log in", "login", "/login", "unauthorized", "authenticate",
  "api key", "401", "sign in", "credentials", "invalid x-api-key"];

let current: OnboardingWindowController | null = null;
let ipcRegistered = false;

function registerIpc(): void {
  if (ipcRegistered) return;
  ipcRegistered = true;
  ipcMain.on("onboarding:action", (e: IpcMainEvent, action: OnboardingAction) => {
    const c = current;
    if (!c || !action || typeof action !== "object") return;
    c.handle(e, action);
  });
}

export class OnboardingWindowController {
  private win: BrowserWindow | null = null;
  private step: Step = "welcome";
  private renderQueued = false;

  // Avatar step
  private previewFrames: string[] = [];
  private usingCustomSheet = Sprites.hasCustom();
  private sheetError: string | null = null;
  private promptCopied = false;
  private importing = false;

  // Dependency step
  private whisperFound = false;
  private ffmpegFound = false;
  private depsChecked = false;
  private modelInstalled = false;
  private usingWhisperCpp = false;
  private modelDownloading = false;
  private modelProgress = 0;
  private modelError: string | null = null;
  /// Set while installWhisper runs, so the step fills itself in as whisper
  /// lands -- no Re-check click needed.
  private installing = false;
  private installMessage = "";
  private installProgress: number | null = null;
  private installError: string | null = null;
  private agentCopied: CodingAgent | null = null;

  // WhatsApp step
  private waConnecting = false;
  private waConnected = Settings.whatsappConnected;
  private waPollTimer: NodeJS.Timeout | null = null;
  /// Set when Connect can't get anywhere. Without it the wizard sat on
  /// "Waiting for QR scan…" forever, which is indistinguishable from a hang.
  private waLaunchFailed: string | null = null;

  // Google step
  private googlePoll: NodeJS.Timeout | null = null;
  /// How "Connect Google" starts the flow. main.ts points this at the
  /// calendar watcher's reauthenticate() so calendar polling starts the
  /// moment consent finishes; until then it goes straight to GoogleAuth.
  onConnectGoogle: (() => void) | null = null;

  // Agent step
  private chosenAgent: CodingAgent = Settings.connectedAgent;
  /// Latest test result per agent; absent while that agent is still being tested.
  private agentHealth = new Map<CodingAgent, AgentHealth>();
  private agentTestRun = 0;

  private promptCopiedTimer: NodeJS.Timeout | null = null;
  private agentCopiedTimer: NodeJS.Timeout | null = null;

  constructor(private readonly momGenerator: MOMGenerator) {
    current = this;
    registerIpc();
    this.previewFrames = OnboardingWindowController.idleFrames();
  }

  show(): void {
    current = this;
    this.refreshDeps();
    this.refreshAvailableAgents();
    if (this.step === "avatar") this.startPreview();
    if (!this.win || this.win.isDestroyed()) this.createWindow();
    const w = this.win!;
    if (w.isMinimized()) w.restore();
    w.show();
    w.focus();
    this.render();
  }

  private createWindow(): void {
    const w = new BrowserWindow({
      width: 500,
      height: 640,
      useContentSize: true,
      resizable: false,
      maximizable: false,
      fullscreenable: false,
      title: "Set up Nikxel",
      autoHideMenuBar: true,
      show: false,
      webPreferences: {
        preload: preloadPath("onboarding"),
        contextIsolation: true,
        nodeIntegration: false,
        spellcheck: false,
      },
    });
    w.setMenuBarVisibility(false);
    w.loadFile(rendererPath("onboarding")).catch(e => diag("onboarding", `load failed: ${e}`));
    w.on("closed", () => {
      if (this.win === w) this.win = null;
      // Nobody is watching for the QR scan any more; reopening offers
      // Connect again rather than a spinner with nothing behind it.
      if (this.waConnecting) { this.waConnecting = false; this.stopPolling(); }
    });
    this.win = w;
  }

  // MARK: - Rendering

  private go(next: Step): void {
    if (this.step === "whatsapp") this.stopPolling();
    if (next === "agent") this.refreshAvailableAgents();
    this.step = next;
    if (next === "avatar") this.startPreview();
    this.render();
  }

  /// Coalesces bursts (download progress, agents landing one by one) into
  /// one push to the page.
  private render(): void {
    if (this.renderQueued) return;
    this.renderQueued = true;
    setTimeout(() => {
      this.renderQueued = false;
      const w = this.win;
      if (!w || w.isDestroyed()) return;
      w.webContents.send("onboarding:state", this.view());
    }, 40);
  }

  private view(): OnboardingView {
    const testing = this.agentHealth.size < CODING_AGENTS.length;
    let googleConnected = false, oneClick = true;
    try { googleConnected = GoogleAuth.shared.isAuthorized; oneClick = GoogleAuth.shared.isOneClick; } catch { /* not ready */ }
    return {
      step: this.step,
      name: Settings.hasUserName ? Settings.userName : (accountName() ?? ""),
      sprites: { cols: Sprites.cols, rows: Sprites.rows, frameSize: Sprites.frameSize },
      avatar: {
        frames: this.previewFrames,
        usingCustom: this.usingCustomSheet,
        sheetError: this.sheetError,
        promptCopied: this.promptCopied,
        importing: this.importing,
      },
      deps: {
        whisperFound: this.whisperFound, ffmpegFound: this.ffmpegFound, depsChecked: this.depsChecked,
        usingWhisperCpp: this.usingWhisperCpp, modelInstalled: this.modelInstalled,
        modelName: safeModelName(), modelSize: MODEL_DOWNLOAD_SIZE,
        modelDownloading: this.modelDownloading, modelProgress: this.modelProgress, modelError: this.modelError,
        installing: this.installing, installMessage: this.installMessage, installProgress: this.installProgress,
        installError: this.installError,
        language: Settings.transcriptionLanguage, languageOptions: LANGUAGE_OPTIONS,
      },
      whatsapp: { connecting: this.waConnecting, connected: this.waConnected, launchFailed: this.waLaunchFailed },
      google: { connected: googleConnected, oneClick },
      agents: CODING_AGENTS.map(agent => {
        const health = this.agentHealth.get(agent);
        const d = OnboardingWindowController.describe(health, agent);
        return {
          id: agent,
          name: AGENT_INFO[agent].displayName,
          status: d.text,
          tone: d.tone,
          hint: d.hint,
          copied: this.agentCopied === agent,
          enabled: health !== undefined && !(health.working === false && health.notInstalled),
          chosen: agent === this.chosenAgent,
        };
      }),
      agentsTesting: testing,
    };
  }

  /// Status line, its colour, and an optional copyable terminal command.
  /// Login is fixed by running the agent itself, so that's the command shown.
  static describe(health: AgentHealth | undefined, agent: CodingAgent): { text: string; tone: Tone; hint: string | null } {
    const install = AGENT_INFO[agent].installCommand;
    if (health === undefined) return { text: "Testing…", tone: "secondary", hint: null };
    if (health.working) {
      return { text: "✓ Installed, logged in and working" + (health.detail ? ` (${health.detail})` : ""), tone: "green", hint: null };
    }
    if (health.notInstalled) return { text: "Not installed", tone: "secondary", hint: install };
    const why = health.reason;
    const lower = why.toLowerCase();
    if (AUTH_HINTS.some(h => lower.includes(h))) return { text: "Installed, but not logged in", tone: "orange", hint: agent };
    if (/won't start|--version|exited with code|cannot find module|is not recognized|enoent/i.test(why)) {
      return { text: `Installed but won't start: ${why}`, tone: "red", hint: install };
    }
    return { text: `Installed, but a test request failed: ${why}`, tone: "red", hint: null };
  }

  // MARK: - Actions

  handle(e: IpcMainEvent, a: OnboardingAction): void {
    if (!this.win || e.sender !== this.win.webContents) return;
    switch (a.type) {
      case "ready": this.render(); break;
      case "go": if (STEPS.includes(a.step)) this.go(a.step); break;
      case "welcomeNext": {
        const typed = String(a.name ?? "").trim();
        if (typed) Settings.userName = typed;
        this.go("avatar");
        break;
      }
      case "copyPrompt": this.copyPrompt(); break;
      case "chooseSheet": void this.chooseSheet(); break;
      case "resetSheet": this.resetSheet(); break;
      case "installDeps": void this.installDeps(); break;
      case "recheckDeps": this.refreshDeps(); break;
      case "downloadModel": void this.downloadModel(); break;
      case "pickLanguage":
        if (LANGUAGE_OPTIONS.some(o => o.code === a.code)) { Settings.transcriptionLanguage = a.code; this.render(); }
        break;
      case "waConnect": void this.startWhatsAppConnect(); break;
      case "googleConnect": this.connectGoogle(); break;
      case "pickAgent": if (CODING_AGENTS.includes(a.agent)) { this.chosenAgent = a.agent; this.render(); } break;
      case "copyInstall": this.copyInstallCommand(a.agent); break;
      case "recheckAgents": this.refreshAvailableAgents(); break;
      case "finish": this.finishSetup(); break;
    }
  }

  private connectGoogle(): void {
    // Through the watcher (when main.ts wired it) so calendar polling starts
    // the moment consent finishes; this page just watches for the token.
    try {
      if (this.onConnectGoogle) this.onConnectGoogle();
      else GoogleAuth.shared.reauthenticate();
    } catch (e) {
      diag("onboarding", `connect Google failed: ${e}`);
    }
    const started = Date.now();
    if (this.googlePoll) clearInterval(this.googlePoll);
    this.googlePoll = setInterval(() => {
      let ok = false;
      try { ok = GoogleAuth.shared.isAuthorized; } catch { /* not ready */ }
      if (ok || Date.now() - started > 300_000) {
        if (this.googlePoll) clearInterval(this.googlePoll);
        this.googlePoll = null;
        if (this.step === "google") this.render();
      }
    }, 1500);
  }

  private copyInstallCommand(agent: CodingAgent): void {
    if (!CODING_AGENTS.includes(agent)) return;
    clipboard.writeText(OnboardingWindowController.describe(this.agentHealth.get(agent), agent).hint ?? AGENT_INFO[agent].installCommand);
    this.agentCopied = agent;
    this.render();
    if (this.agentCopiedTimer) clearTimeout(this.agentCopiedTimer);
    this.agentCopiedTimer = setTimeout(() => {
      if (this.step !== "agent") return;
      this.agentCopied = null;
      this.render();
    }, 2000);
  }

  private async downloadModel(): Promise<void> {
    if (this.modelDownloading) return;
    this.modelDownloading = true;
    this.modelProgress = 0;
    this.modelError = null;
    this.render();
    try {
      await downloadModel((_msg, frac) => {
        // Only the bar moves; render() coalesces the bursts.
        if (typeof frac === "number" && Number.isFinite(frac)) this.modelProgress = Math.max(0, Math.min(1, frac));
        this.render();
      });
    } catch (e) {
      this.modelError = `Download failed: ${e instanceof Error ? e.message : e}`;
    }
    this.modelDownloading = false;
    this.refreshDeps();
    this.render();
  }

  private finishSetup(): void {
    Settings.connectedAgent = this.chosenAgent;
    Settings.onboardingCompleted = true;
    this.stopPolling();
    bus.emit("menuChanged");
    this.win?.close();
  }

  // MARK: - Avatar actions

  private copyPrompt(): void {
    const text = readText(resourcePath("sprite_prompt.txt"));
    if (text === null) {
      this.sheetError = "Couldn't find the bundled prompt.";
      this.render();
      return;
    }
    clipboard.writeText(text);
    this.promptCopied = true;
    this.render();
    if (this.promptCopiedTimer) clearTimeout(this.promptCopiedTimer);
    this.promptCopiedTimer = setTimeout(() => {
      if (this.step !== "avatar") return;
      this.promptCopied = false;
      this.render();
    }, 2000);
  }

  private async chooseSheet(): Promise<void> {
    if (this.importing || !this.win) return;
    const r = await dialog.showOpenDialog(this.win, {
      title: "Pick the sprite sheet Gemini gave you",
      filters: [{ name: "PNG image", extensions: ["png"] }],
      properties: ["openFile"],
    });
    const file = r.filePaths[0];
    if (r.canceled || !file) return;

    this.sheetError = null;
    this.importing = true;
    this.render();

    let failure: string | null = null;
    try {
      // Keys out the magenta, finds the real grid and re-frames every
      // cell -- whatever Gemini returned, this is what makes it
      // usable, so the user never has to run remove_magenta.py.
      const data = await SpriteSheetImporter.process(file);
      await fs.promises.rm(Sprites.customPath, { force: true });
      await fs.promises.writeFile(Sprites.customPath, data);
    } catch (e) {
      failure = e instanceof Error ? e.message : String(e);
    }
    this.importing = false;
    this.sheetError = failure;
    if (failure === null) {
      this.usingCustomSheet = true;
      bus.emit("spritesChanged");
      this.startPreview();
    }
    this.render();
  }

  private resetSheet(): void {
    try { fs.rmSync(Sprites.customPath, { force: true }); } catch { /* already gone */ }
    this.sheetError = null;
    this.usingCustomSheet = Sprites.hasCustom();
    bus.emit("spritesChanged");
    this.startPreview();
    this.render();
  }

  // MARK: - Dependency actions

  /// No Homebrew or Terminal on Windows: installWhisper downloads the
  /// official whisper.cpp release into ~/.nikxel/bin/whisper in the
  /// background, and the page shows its progress. ffmpeg ships with Nikxel.
  private async installDeps(): Promise<void> {
    if (this.installing) return;
    this.installing = true;
    this.installError = null;
    this.installMessage = "";
    this.installProgress = null;
    this.render();
    try {
      await installWhisper((msg, frac) => {
        this.installMessage = msg;
        this.installProgress = typeof frac === "number" && Number.isFinite(frac) ? Math.max(0, Math.min(1, frac)) : null;
        this.render();
      });
    } catch (e) {
      this.installError = `Install failed: ${e instanceof Error ? e.message : e}`;
    }
    this.installing = false;
    this.refreshDeps();
    this.render();
  }

  private async startWhatsAppConnect(): Promise<void> {
    this.waLaunchFailed = null;
    this.waConnecting = true;
    this.render();
    try {
      await ChromeWhatsApp.openForLogin();
      this.beginPolling();
    } catch (e) {
      this.waConnecting = false;
      this.waLaunchFailed = e instanceof Error ? e.message : String(e);
      this.render();
    }
  }

  // MARK: - Background checks

  private async refreshDeps(): Promise<void> {
    let whisperPath: string | null = null;
    try { whisperPath = new Transcriber().findBinary(); } catch (e) { diag("onboarding", `findBinary failed: ${e}`); }
    const whisper = whisperPath !== null;
    const isCpp = whisperPath !== null && isWhisperCpp(whisperPath);
    let model = false;
    try { model = hasModel(); } catch { /* treat as missing */ }
    let ffmpeg = false;
    try { ffmpeg = ffmpegPath() !== null; } catch { /* treat as missing */ }

    const changed = !this.depsChecked || this.usingWhisperCpp !== isCpp || this.modelInstalled !== model
      || this.whisperFound !== whisper || this.ffmpegFound !== ffmpeg;
    this.usingWhisperCpp = isCpp;
    this.modelInstalled = model;
    this.whisperFound = whisper;
    this.ffmpegFound = ffmpeg;
    this.depsChecked = true;
    if (this.step !== "deps") return;
    // whisper.cpp with no model can't transcribe: fetch it now instead of
    // waiting for another click. Not after a failure -- that leaves the
    // button up for a retry instead of looping.
    if (isCpp && !model && !this.modelDownloading && this.modelError === null) {
      void this.downloadModel();
    } else if (changed) {
      this.render();
    }
  }

  /// Tests every agent in parallel: installed, starts, and answers a real
  /// prompt (which is what proves it's logged in). Results land one by one so
  /// a slow agent doesn't hold up the others; `agentTestRun` discards the
  /// answers of a superseded run.
  private refreshAvailableAgents(): void {
    this.agentTestRun += 1;
    const runId = this.agentTestRun;
    this.agentHealth.clear();
    if (this.step === "agent") this.render();
    for (const agent of CODING_AGENTS) {
      this.momGenerator.checkAgent(agent)
        .catch((e): AgentHealth => ({ working: false, notInstalled: false, reason: e instanceof Error ? e.message : String(e) }))
        .then(health => {
          if (runId !== this.agentTestRun) return;
          this.agentHealth.set(agent, health);
          // Land on the first agent that actually works, unless the user
          // already picked one that does.
          if (this.agentHealth.get(this.chosenAgent)?.working !== true && health.working) {
            this.chosenAgent = agent;
          }
          if (this.step === "agent") this.render();
        });
    }
  }

  private beginPolling(): void {
    this.stopPolling();
    let checking = false;
    this.waPollTimer = setInterval(async () => {
      if (checking) return;
      checking = true;
      try {
        if (!(await ChromeWhatsApp.isLoggedIn())) return;
        this.waConnected = true;
        this.waConnecting = false;
        Settings.whatsappConnected = true;
        bus.emit("menuChanged");
        this.stopPolling();
        this.render();
      } catch { /* window still loading; next tick */ } finally {
        checking = false;
      }
    }, 2000);
  }

  private stopPolling(): void {
    if (this.waPollTimer) clearInterval(this.waPollTimer);
    this.waPollTimer = null;
  }

  // MARK: - Avatar preview

  /// Row 0 (idle) of the active sheet, which the page animates. A single
  /// static frame would hide a wrong row layout, which is the most likely way
  /// a user's sheet is broken -- the animation shows it immediately.
  private startPreview(): void {
    this.previewFrames = OnboardingWindowController.idleFrames();
  }

  /// Row 0 of the active sheet -- the idle animation -- as data URLs. The
  /// avatar actually drawn on screen comes from this sheet; nikxel_avatar.png
  /// is only the no-sprite-sheet fallback, so showing that here would greet
  /// the user with a different character than the app runs.
  private static idleFrames(): string[] {
    const f = Sprites.frameSize;
    const frames: string[] = [];
    try {
      const sheet = nativeImage.createFromPath(Sprites.activePath());
      if (!sheet.isEmpty()) {
        const size = sheet.getSize();
        for (let col = 0; col < Sprites.cols; col++) {
          if ((col + 1) * f > size.width || f > size.height) break;
          frames.push(sheet.crop({ x: col * f, y: 0, width: f, height: f }).toDataURL());
        }
      }
      if (frames.length === 0) {
        const fallback = nativeImage.createFromPath(resourcePath("nikxel_avatar.png"));
        if (!fallback.isEmpty()) frames.push(fallback.toDataURL());
      }
    } catch (e) {
      diag("onboarding", `preview frames failed: ${e}`);
    }
    return frames;
  }
}

/// The name field's starting value when the user never typed one: the
/// account's first name if it reads like a real name. Settings.userName
/// already falls back to it (then to "Me"), so anything but "Me" is it.
function accountName(): string | null {
  const n = Settings.userName;
  return n === "Me" ? null : n;
}

function safeModelName(): string {
  try { return path.basename(modelPath()); } catch { return "ggml-small.bin"; }
}

/// whisper.cpp (what installWhisper fetches) ships no model of its own;
/// openai-whisper (a pip "whisper.exe") downloads its own. The cpp builds
/// are whisper-cli.exe / main.exe, or anything under ~/.nikxel/bin.
function isWhisperCpp(bin: string): boolean {
  const base = path.basename(bin).toLowerCase();
  if (bin.toLowerCase().includes(`${path.sep}.nikxel${path.sep}`)) return true;
  return base !== "whisper.exe" && base !== "whisper";
}
