import * as fs from "fs";
import * as os from "os";
import * as path from "path";
import { spawn } from "child_process";
import { BrowserWindow, clipboard, dialog, ipcMain, IpcMainEvent, nativeImage } from "electron";
import { HOME, preloadPath, rendererPath, resourcePath, readText } from "../core/paths";
import { which } from "../core/proc";
import { ui } from "../core/ui";
import { Settings, Sprites, CODING_AGENTS, AGENT_INFO, CodingAgent } from "../core/settings";
import { bus } from "../core/bus";
import { diag } from "../core/diag";
import type { MOMGenerator, AgentHealth } from "../recording/momGenerator";
import { Transcriber, ffmpegPath, hasModel, modelPath, downloadModel, installWhisper } from "../recording/transcriber";
import { ChromeWhatsApp } from "../whatsapp/chromeWhatsApp";
import { GoogleAuth } from "../google/googleAuth";
import { CoachPointer, windowRectByTitle } from "./coachTour";
import { spriteRows } from "./spriteFrames";
import { SpriteSheetImporter } from "./spriteSheetImporter";
import { CloudSync } from "./cloudSync";

/// First-run (and reopenable-anytime, via the tray) setup wizard: say hello,
/// tour what Nikxel does, pick an avatar, check the transcription tools,
/// connect WhatsApp and Google, and choose which coding agent Nikxel should
/// shell out to. Port of OnboardingWindow.swift. The page is the Mac's own
/// (src/OnboardingPage.swift, pulled in by scripts/copy-static.js); its
/// Mac-only wording switches on `platform: "win"` in the state.
///
/// The state lives here in the main process and the page is only a view of
/// it: closing the window throws the page away, but "Setup Wizard…" reopens
/// on the same step with everything as it was, like the Mac's window that
/// was hidden rather than released.

type Step = "welcome" | "tour" | "avatar" | "deps" | "whatsapp" | "google" | "agent" | "ready";
const STEPS: Step[] = ["welcome", "tour", "avatar", "deps", "whatsapp", "google", "agent", "ready"];
type Tone = "muted" | "red" | "orange" | "green";

/// What the page posts (webkit.messageHandlers.nx in OnboardingPage.swift).
export interface OnboardingAction {
  type: "go" | "copyPrompt" | "chooseSheet" | "photoAvatar" | "resetSheet" | "downloadModel" | "installDeps" | "recheckDeps" | "language"
    | "connectWhatsApp" | "getChrome" | "connectGoogle" | "pickAgent" | "copyAgent" | "installAgent" | "retestAgents" | "finish";
  step?: string; name?: string; code?: string; index?: number;
}

/// "en" handles all three cases and is what almost everyone should use.
/// Measured on the small model: English stays clean, Hindi comes back as
/// natural Hinglish with English words spelled properly ("Namaste, mai kal
/// meeting me shamil nahi ho paunga"), and Hinglish resolves to English.
/// Picking "hi" makes pure English come out as Devanagari gibberish, and
/// auto-detect reads Indian-accented English as Hindi.
const LANGUAGE_OPTIONS = [
  { title: "English", note: "Also Hindi & Hinglish", code: "en" },
  { title: "Hindi", note: "Breaks pure English", code: "hi" },
  { title: "Auto-detect", note: "Misreads Indian English", code: "auto" },
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
  private pageLoaded = false;
  private step: Step = "welcome";
  private renderQueued = false;

  // Avatar step
  private usingCustomSheet = Sprites.hasCustom();
  private sheetError: string | null = null;
  private promptCopied = false;
  private importing = false;
  private drawing = false;

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
  /// Setup finished: main.ts starts the first-run tour.
  onFinished: (() => void) | null = null;

  // Agent step
  private chosenAgent: CodingAgent = Settings.connectedAgent;
  /// Latest test result per agent; absent while that agent is still being tested.
  private agentHealth = new Map<CodingAgent, AgentHealth>();
  private agentTestRun = 0;
  /// Set while the PowerShell window installing (or signing in to) Claude
  /// Code is open; checks every few seconds until Claude answers.
  private agentInstallPoll: NodeJS.Timeout | null = null;
  /// The arrow at that PowerShell window, saying what to do at each stage.
  private installPointer: CoachPointer | null = null;
  private installStage = "";

  private promptCopiedTimer: NodeJS.Timeout | null = null;
  private agentCopiedTimer: NodeJS.Timeout | null = null;

  constructor(private readonly momGenerator: MOMGenerator) {
    current = this;
    registerIpc();
  }

  show(): void {
    current = this;
    this.refreshDeps();
    this.refreshAvailableAgents();
    if (!this.win || this.win.isDestroyed()) this.createWindow();
    const w = this.win!;
    if (w.isMinimized()) w.restore();
    w.show();
    w.focus();
    this.render();
  }

  private createWindow(): void {
    const w = new BrowserWindow({
      width: 1160,
      height: 860,
      minWidth: 980,
      minHeight: 780,
      title: "Set up Nikxel",
      autoHideMenuBar: true,
      // The page's paper, so nothing flashes white before it paints.
      backgroundColor: "#f6f4ee",
      show: false,
      webPreferences: {
        preload: preloadPath("onboarding"),
        contextIsolation: true,
        nodeIntegration: false,
        spellcheck: false,
      },
    });
    w.setMenuBarVisibility(false);
    w.once("ready-to-show", () => w.show());
    // Each (re)load plays the splash again; the step and everything set so
    // far live here, so the page comes back where the user left it.
    w.webContents.on("did-finish-load", () => {
      this.pageLoaded = true;
      void w.webContents.executeJavaScript(`nx.frames(${JSON.stringify(spriteRows())})`).catch(() => {});
      this.render();
    });
    // Links in the page never navigate it away.
    w.webContents.on("will-navigate", e => e.preventDefault());
    w.loadFile(rendererPath("onboarding")).catch(e => diag("onboarding", `load failed: ${e}`));
    w.on("closed", () => {
      if (this.win === w) { this.win = null; this.pageLoaded = false; }
      // Nobody is watching for the QR scan any more; reopening offers
      // Connect again rather than a spinner with nothing behind it.
      if (this.waConnecting) { this.waConnecting = false; this.stopPolling(); }
      // Closed before "Start using Nikxel": still show them around (once), and
      // the tour's end asks for permissions. Setup reopens at the next launch.
      if (!Settings.onboardingCompleted) {
        diag("onboarding", "closed before finishing");
        setTimeout(() => this.onFinished?.(), 1200);
      }
    });
    this.win = w;
  }

  // MARK: - Rendering

  private go(next: Step): void {
    if (this.step === "whatsapp") this.stopPolling();
    if (next === "agent") this.refreshAvailableAgents();
    this.step = next;
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
      if (!w || w.isDestroyed() || !this.pageLoaded) return;
      void w.webContents.executeJavaScript(`nx.state(${JSON.stringify(this.view())})`).catch(() => {});
    }, 40);
  }

  /// Everything the page draws, in the shape OnboardingWindowController.state()
  /// gives the Mac page.
  private view(): Record<string, unknown> {
    let googleConnected = false, oneClick = true;
    try { googleConnected = GoogleAuth.shared.isAuthorized; oneClick = GoogleAuth.shared.isOneClick; } catch { /* not ready */ }
    const { cols, rows, frameSize: f } = Sprites;
    return {
      platform: "win",
      step: this.step,
      name: Settings.hasUserName ? Settings.userName : (accountName() ?? ""),
      avatar: {
        custom: this.usingCustomSheet, error: this.sheetError ?? "", copied: this.promptCopied, importing: this.importing, drawing: this.drawing,
        spec: `PNG, ${cols} columns × ${rows} rows of ${f}px frames (${cols * f}×${rows * f}). One row per state: idle, typing, thinking, done, dragging, pounce, petted, alert, recording, MOM ready.`,
      },
      deps: {
        checked: this.depsChecked, whisper: this.whisperFound, ffmpeg: this.ffmpegFound, brew: false,
        cpp: this.usingWhisperCpp, model: this.modelInstalled, downloading: this.modelDownloading,
        progress: this.modelProgress, modelError: this.modelError ?? "",
        modelName: safeModelName(), modelSize: MODEL_DOWNLOAD_SIZE,
        installing: this.installing, installMessage: this.installMessage, installProgress: this.installProgress,
        installError: this.installError ?? "",
        ready: this.whisperFound && this.ffmpegFound && (!this.usingWhisperCpp || this.modelInstalled),
        language: Settings.transcriptionLanguage, languages: LANGUAGE_OPTIONS,
      },
      // WhatsApp runs in Nikxel's own window: no browser to find or port to free.
      wa: {
        browser: "WhatsApp", noBrowser: false, launchFailed: this.waLaunchFailed !== null, error: this.waLaunchFailed ?? "",
        connected: this.waConnected, connecting: this.waConnecting, missing: "", port: 0,
      },
      google: { connected: googleConnected, oneClick, waiting: this.googlePoll !== null },
      agents: CODING_AGENTS.map(agent => {
        const health = this.agentHealth.get(agent);
        const d = OnboardingWindowController.describe(health, agent);
        // Claude Code gets a button that does it all; the others keep a command to copy.
        let action = "";
        if (agent === "claude" && health && !health.working) {
          action = health.notInstalled ? "install" : d.tone === "orange" ? "login" : "";
        }
        if (agent === "claude" && this.agentInstallPoll && !health?.working && !action) action = "install";
        return {
          name: AGENT_INFO[agent].displayName, text: d.text, tone: d.tone, hint: d.hint ?? "",
          enabled: health !== undefined && !(health.working === false && health.notInstalled),
          chosen: agent === this.chosenAgent, copied: this.agentCopied === agent,
          action, busy: agent === "claude" && this.agentInstallPoll !== null,
        };
      }),
      testing: this.agentHealth.size < CODING_AGENTS.length,
    };
  }

  /// Status line, its colour, and an optional copyable terminal command.
  /// Login is fixed by running the agent itself, so that's the command shown.
  static describe(health: AgentHealth | undefined, agent: CodingAgent): { text: string; tone: Tone; hint: string | null } {
    const install = AGENT_INFO[agent].installCommand;
    if (health === undefined) return { text: "Testing…", tone: "muted", hint: null };
    if (health.working) {
      return { text: "Installed, logged in and working" + (health.detail ? ` (${health.detail})` : ""), tone: "green", hint: null };
    }
    if (health.notInstalled) return { text: "Not installed", tone: "muted", hint: install };
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
    const agent = CODING_AGENTS[a.index ?? -1];
    switch (a.type) {
      case "go": {
        const next = a.step as Step;
        if (!STEPS.includes(next)) return;
        const typed = String(a.name ?? "").trim();
        if (this.step === "welcome" && typed) Settings.userName = typed;
        if (this.step === "agent" && next === "ready") Settings.connectedAgent = this.chosenAgent;
        this.go(next);
        break;
      }
      case "copyPrompt": this.copyPrompt(); break;
      case "chooseSheet": void this.chooseSheet(); break;
      case "photoAvatar": void this.makeFromPhoto(); break;
      case "resetSheet": this.resetSheet(); break;
      case "installDeps": void this.installDeps(); break;
      case "recheckDeps": void this.refreshDeps(); break;
      case "downloadModel": void this.downloadModel(); break;
      case "language":
        if (LANGUAGE_OPTIONS.some(o => o.code === a.code)) { Settings.transcriptionLanguage = String(a.code); this.render(); }
        break;
      case "connectWhatsApp": void this.startWhatsAppConnect(); break;
      case "connectGoogle": this.connectGoogle(); break;
      case "pickAgent": if (agent) { this.chosenAgent = agent; this.render(); } break;
      case "copyAgent": if (agent) this.copyInstallCommand(agent); break;
      case "installAgent": this.installClaude(); break;
      case "retestAgents": this.refreshAvailableAgents(); break;
      case "finish": this.finishSetup(); break;
      // "getChrome": the Mac's WhatsApp needs Chrome; Windows' runs in Nikxel.
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
    this.render();
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

  /// Installs Claude Code (if missing) and starts it to sign in, in a
  /// PowerShell window the user can watch, while Nikxel's bubble says what to
  /// press. Anthropic's installer needs no Node. Checks in the background and
  /// turns the step green once Claude answers. Port of OnboardingWindow.installClaude.
  private installClaude(): void {
    if (this.agentInstallPoll) return;
    const script = [
      "$Host.UI.RawUI.WindowTitle = 'Setting up Claude Code for Nikxel'",
      "$bin = Join-Path $env:USERPROFILE '.local\\bin'",
      "$env:Path = \"$bin;$env:Path\"",
      "if (-not (Get-Command claude -ErrorAction SilentlyContinue)) {",
      "  Write-Host 'Installing Claude Code for Nikxel. This takes a minute...'",
      "  Write-Host ''",
      "  irm https://claude.ai/install.ps1 | iex",
      "  $env:Path = \"$bin;$env:Path\"",
      "}",
      "Write-Host ''",
      "Write-Host 'Now sign in: press Enter to pick a look, choose your Claude account, and finish in the browser.'",
      "Write-Host 'Nikxel notices when it works. You can close this window after that.'",
      "Write-Host ''",
      "claude",
    ].join("\r\n");
    const file = path.join(os.tmpdir(), "nikxel-install-claude.ps1");
    try {
      // BOM: Windows PowerShell 5.1 reads a BOM-less script as the ANSI code page.
      fs.writeFileSync(file, "\ufeff" + script, "utf8");
      // `start` gives it a window of its own, which stays after Nikxel's side is done.
      // Verbatim: Node's own quoting of the title becomes \" , which cmd's start misreads.
      spawn("cmd.exe", ["/c", `start "Claude Code" powershell -NoProfile -NoExit -ExecutionPolicy Bypass -File "${file}"`],
        { detached: true, stdio: "ignore", windowsHide: true, windowsVerbatimArguments: true }).unref();
    } catch (e) {
      diag("onboarding", `couldn't open the Claude install window: ${e}`);
      return;
    }
    diag("onboarding", "opened PowerShell to install/sign in to Claude Code");
    ui.tell({ icon: "🧑‍💻", title: "Setting up Claude Code", lifetime: 180, lines: [
      "In the window I opened, let it install.",
      "When Claude starts, press Enter, choose your Claude account and sign in in your browser.",
      "I'll notice when it works.",
    ] });

    const pointer = new CoachPointer();
    this.installPointer = pointer;
    this.installStage = "";
    pointer.onNext = pointer.onSkip = () => this.closeInstallPointer();

    // Cheap file checks until it's installed, then a real test every 20 s
    // (it sends a tiny prompt) until it answers. Gives up after 20 minutes.
    const started = Date.now();
    let lastTest = 0, testing = false;
    this.agentInstallPoll = setInterval(() => {
      if (Date.now() - started > 20 * 60_000) { this.stopInstallPoll(); this.closeInstallPointer(); this.render(); return; }
      const installed = fs.existsSync(path.join(HOME, ".local", "bin", "claude.exe")) || which("claude") !== null;
      void this.guideInstall(installed ? "login" : "installing");
      if (!installed || testing || Date.now() - lastTest < 20_000) return;
      testing = true; lastTest = Date.now();
      void this.momGenerator.checkAgent("claude")
        .catch((e): AgentHealth => ({ working: false, notInstalled: false, reason: e instanceof Error ? e.message : String(e) }))
        .then(health => {
          testing = false;
          this.agentHealth.set("claude", health);
          if (health.working) {
            this.stopInstallPoll();
            void this.guideInstall("done");
            this.chosenAgent = "claude";
            diag("onboarding", "Claude Code installed and signed in");
            ui.tell({ icon: "✅", title: "Claude Code is ready", lines: ["You can close the PowerShell window. Click Next."], kind: "success" });
          }
          this.render();
        });
    }, 4000);
    this.render();
  }

  /// Points at the PowerShell window with what to do now. Re-placed every
  /// tick, so it follows the window if the user moves it.
  private async guideInstall(stage: string): Promise<void> {
    const pointer = this.installPointer;
    if (!pointer) return;
    const target = await windowRectByTitle("Setting up Claude Code for Nikxel");
    if (!target || pointer !== this.installPointer) return;
    if (stage !== this.installStage) diag("onboarding", `Claude setup stage → ${stage}`);
    this.installStage = stage;
    pointer.show(target, stage === "installing"
      ? { title: "Installing Claude Code…", step: 0, total: 3, primary: "Hide",
          text: "<p>This window is installing it. Nothing to do yet; it takes a minute.</p>" }
      : stage === "login"
        ? { title: "Now sign in to Claude", step: 1, total: 3, primary: "Hide",
            text: "<p>In this window: press <kbd>Enter</kbd> to pick a look, then choose your <b>Claude account</b>.</p><p>Your browser opens. Sign in there and click <b>Authorize</b>.</p>" }
        : { title: "Claude Code is ready ✓", step: 2, total: 3, primary: "Done",
            text: "<p>You can close this window. Back in setup, click <b>Next</b>.</p>" });
  }

  private closeInstallPointer(): void {
    this.installPointer?.close();
    this.installPointer = null;
  }

  private stopInstallPoll(): void {
    if (this.agentInstallPoll) clearInterval(this.agentInstallPoll);
    this.agentInstallPoll = null;
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
        // Nudge the page's bar rather than resending the whole state.
        if (this.pageLoaded) void this.win?.webContents.executeJavaScript(`nx.progress(${this.modelProgress})`).catch(() => {});
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
    setTimeout(() => this.onFinished?.(), 1200);
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

    await this.importSheet(async () => file);
  }

  /// Setup's "Make me from a photo": nikxel-api has Gemini draw the sheet
  /// (its key, its prompts; the photo isn't kept), then the usual import.
  private async makeFromPhoto(): Promise<void> {
    if (this.importing || !this.win) return;
    const r = await dialog.showOpenDialog(this.win, {
      title: "Pick a clear photo of your face",
      filters: [{ name: "Photo", extensions: ["jpg", "jpeg", "png"] }],
      properties: ["openFile"],
    });
    const file = r.filePaths[0];
    if (r.canceled || !file) return;
    this.drawing = true;
    await this.importSheet(async () => {
      try { return await OnboardingWindowController.drawSheet(file); } finally { this.drawing = false; }
    });
  }

  /// The photo, at most 1024px and as JPEG, to /api/avatar; the sheet it returns, as a temp file.
  private static async drawSheet(file: string): Promise<string> {
    let img = nativeImage.createFromPath(file);
    if (img.isEmpty()) throw new Error("Couldn’t open that photo. Try a JPEG or PNG.");
    const { width, height } = img.getSize();
    if (Math.max(width, height) > 1024) img = img.resize(width >= height ? { width: 1024 } : { height: 1024 });
    let res: Response;
    try {
      res = await fetch(CloudSync.backendBase() + "/api/avatar", {
        method: "POST", headers: { "content-type": "application/json" },
        body: JSON.stringify({ photo: img.toJPEG(85).toString("base64"), mime: "image/jpeg" }),
        signal: AbortSignal.timeout(240_000),
      });
    } catch { throw new Error("Couldn’t reach Nikxel’s server. Check your internet and try again."); }
    let obj: { image?: string; error?: string };
    try { obj = await res.json() as typeof obj; } catch { throw new Error("Nikxel’s server didn’t answer properly. Try again."); }
    if (!obj.image) throw new Error(obj.error || "Couldn’t draw you just now. Try again.");
    const out = path.join(os.tmpdir(), "nikxel-avatar-sheet.png");
    await fs.promises.writeFile(out, Buffer.from(obj.image, "base64"));
    return out;
  }

  /// Imports the sheet `source` gives (it may take a while).
  private async importSheet(source: () => Promise<string>): Promise<void> {
    this.sheetError = null;
    this.importing = true;
    this.render();

    let failure: string | null = null;
    try {
      // Keys out the magenta, finds the real grid and re-frames every
      // cell -- whatever Gemini returned, this is what makes it
      // usable, so the user never has to run remove_magenta.py.
      const data = await SpriteSheetImporter.process(await source());
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
      this.pushFrames();
    }
    this.render();
  }

  private resetSheet(): void {
    try { fs.rmSync(Sprites.customPath, { force: true }); } catch { /* already gone */ }
    this.sheetError = null;
    this.usingCustomSheet = Sprites.hasCustom();
    bus.emit("spritesChanged");
    this.pushFrames();
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

  // MARK: - Avatar frames

  /// Every row of the active sheet: the page plays the row that fits each
  /// step, and the avatar step previews idle, where a wrong row layout (the
  /// likeliest way a user's sheet is broken) shows at once.
  private pushFrames(): void {
    if (this.pageLoaded) void this.win?.webContents.executeJavaScript(`nx.frames(${JSON.stringify(spriteRows())})`).catch(() => {});
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
