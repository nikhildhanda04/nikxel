# Nikxel for Windows: porting contract

This is an Electron + TypeScript port of the Swift macOS app in `../src/`.
The goal is feature parity: same features, same behaviour, same files on disk
(`~/.nikxel/...`, `Documents/nikxel/...`), same wording in bubbles and menus,
with Windows equivalents wherever macOS APIs were used.

This file is the interface between the module groups. **Exported names and
signatures listed here are fixed.** Other modules code against them before
yours exists. Anything not listed is yours to shape.

## Ground rules

- **Port faithfully.** Read the Swift file(s) in full and carry the logic,
  constants, prompts, timings, edge cases and comments across. The Swift
  comments explain *why*; keep the ones that still apply, in the same voice
  (`///` doc comments above declarations, terse inline `//`). Don't summarise
  prompts: copy them verbatim.
- **Async.** Swift completion handlers and background `DispatchQueue` work
  become `async` functions or Promises. Never block the main process: no
  `execSync`, no `readFileSync` of large files in hot paths, no busy loops.
- **Processes.** Use `core/proc.ts` (`run`, `which`, `spawnProcess`,
  `killTree`, `powershell`). It handles npm `.cmd` shims, hidden console
  windows and the PATH a packaged app lacks. Pass long text (prompts) on
  **stdin**, never as a command-line argument: Windows caps a command line at
  32 KB, and at 8 KB when it goes through cmd.exe.
- **Paths.** Use `core/paths.ts`: `nikxelPath(...)` for `~/.nikxel/...`,
  `documentsDir("notes"|"meetings"|"daily")`, `resourcePath(name)` for bundled
  files, `path.join` everywhere (never a hard-coded `/`). File names can't
  contain `: * ? " < > |` on Windows; use `fileStamp()` for timestamps.
- **Logging.** `diag(tag, msg)` (debug.log) and `cblog(msg)` (chatbot.log) from
  `core/diag.ts`, where the Swift used `Diag.log` / `cblog`.
- **Settings.** `Settings` from `core/settings.ts` replaces `NikxelSettings`.
  `Settings.captureMode` replaces `CaptureMode.current`; `Settings.botEnabled`
  stores the WhatsApp master switch. Types `CodingAgent`, `WABotMode`,
  `NoteFormat`, `CaptureMode` and their info tables live there too.
- **UI.** Never import the avatar window. Use `ui` from `core/ui.ts`:
  `ui.showCard`, `ui.tell`, `ui.ask`, `ui.pushReminder`, ... (mirrors
  `nikxelView?.showCard`, `NikxelView.tell`, `NikxelView.ask`).
- **Events.** `bus` from `core/bus.ts` replaces `NotificationCenter`
  (`activeTexterChanged`, `meetingStateChanged`, `spritesChanged`,
  `menuChanged`, `wake`). Emit `menuChanged` when something a tray item
  displays has changed.
- **Opening things.** `openFile`, `openFolder`, `openUrl`, `revealFile` from
  `core/open.ts` (`NSWorkspace.shared.open/openFile`).
- **Clipboard / notifications / dialogs:** Electron's `clipboard`,
  `Notification`, `dialog`.
- **Windows.** Each BrowserWindow uses `contextIsolation: true`,
  `nodeIntegration: false`, a preload in `src/preload/<name>.ts` that imports
  only `electron` and exposes a small API via `contextBridge`. Load pages with
  `win.loadFile(rendererPath("<name>"))`, preload with `preloadPath("<name>")`.
  Renderer code lives in `src/renderer/<name>.ts` (+ `.html`, `.css`), is
  compiled as ES modules (`<script type="module" src="./<name>.js">`), and
  cannot import from `src/main`. IPC channel names are prefixed with the
  window name (`avatar:...`, `recorder:...`, `onboarding:...`).
- **Coordinates.** macOS is y-up with the origin at the bottom-left; the
  browser and Windows are y-down from the top-left. Flip every y when porting
  drawing and hit-testing code.
- **No new runtime dependencies** without a strong reason. Already available:
  `electron`, `ffmpeg-static` (bundled ffmpeg binary: `require("ffmpeg-static")`
  returns its path; in a packaged app replace `app.asar` with
  `app.asar.unpacked` in it), `uiohook-napi` (global keyboard hook), and Node 24
  built-ins including `node:sqlite`.
- **Checks.** The Swift repo has `check_*.swift` scripts for pure logic. Port
  the ones for your modules to `src/checks/<name>.test.ts` using `node:test`
  and `node:assert`. They run under plain Node (`npm run check`), so they must
  not need a live Electron app (a module that imports `electron` at the top
  level still loads; the import just isn't usable).
- **Must compile.** `npm run typecheck` (from `windows/`) must pass for your
  files. You can't run the app on this Mac (it's Windows-targeted), so be
  careful, read Electron's docs for anything you aren't sure of, and keep the
  Windows specifics correct.

## Layout

```
src/main/main.ts                 tray menu + wiring (NikxelApp.swift). Owned by the lead.
src/main/core/*                  shared, already written. Don't change exported signatures.
src/main/avatar/                 Group A
src/main/recording/              Group B
src/main/google/                 Group C
src/main/whatsapp/               Group D
src/main/system/                 Group E
src/preload/<window>.ts
src/renderer/<window>.{ts,html,css}
src/checks/*.test.ts
```

## Group A: avatar (NikxelView, NikxelCard, NikxelWindowController, InputHandler)

`src/main/avatar/avatarWindow.ts`
```ts
export function createAvatarWindow(sm: StateMachine, handlers: { onDoubleClick: () => void }): AvatarSurface & { window: BrowserWindow };
```
Creates the transparent, frameless, always-on-top (`"screen-saver"` level),
skip-taskbar window, renders the avatar, cards, reminder bubbles and every
overlay the Swift view draws, and calls `ui.setAvatar(...)` on itself. It
forwards sprite-state changes from `sm` ("state" events) to the renderer,
handles drag (moving the window and clamping like `mouseDragged`), double-click
→ `handlers.onDoubleClick`, card and button clicks (callbacks stay in main;
the renderer sends back ids), and reminder taps → `ui.reminderWasTapped(id)`.
Click-through: transparent areas must not swallow clicks
(`setIgnoreMouseEvents(true, { forward: true })`, switched off while the
pointer is over the avatar or a card). Reloads sprites on `bus` `spritesChanged`.

`src/main/avatar/inputHandler.ts`
```ts
export class InputHandler {
  constructor(sm: StateMachine, onKeystroke: () => void);
  startMonitoring(): void;
  stopMonitoring(): void;
}
```
Global key-down hook with `uiohook-napi` (no Accessibility prompt on
Windows). Each key-down calls `sm.triggerTyping()` and `onKeystroke()`
(avatarWindow uses it for the WPM overheat).

## Group B: recording & notes (AudioRecorder, MicRecorder, Transcriber, TranscriptMerger, MOMGenerator, NoteExporter, SummaryTemplates, MeetingCoordinator, UsageLog)

`src/main/recording/momGenerator.ts`
```ts
export interface PendingJob { id: string; mode: CaptureMode; startedAt: Date; /* + whatever regenerate needs */ }
export type AgentHealth = { working: true; detail?: string } | { working: false; notInstalled: boolean; reason: string };
export class MOMGenerator {
  generate(transcript: string, mode: CaptureMode, startedAt: Date, durationSec: number): Promise<string>; // resolves to the note's path
  runPrompt(prompt: string, kind: string, claudeModel?: string): Promise<string>;                        // rejects with a readable Error
  findBinary(agent: CodingAgent): string | null;
  checkAgent(agent: CodingAgent): Promise<AgentHealth>;
  unfinishedJobs(): PendingJob[];
  regenerate(job: PendingJob): Promise<string>;
}
```

`src/main/recording/meetingCoordinator.ts`
```ts
export class MeetingCoordinator {
  constructor(sm: StateMachine);
  readonly momGen: MOMGenerator;
  readonly recorder: { isMicMuted: boolean; warmUpPermission(): void };
  readonly isRecording: boolean;
  toggleRecording(force: boolean): void;
}
```
Recording runs in a hidden BrowserWindow (`recorder`): microphone via
`getUserMedia`, system audio via `getDisplayMedia` with
`session.setDisplayMediaRequestHandler(... { video: screenSource, audio: "loopback" })`
(WASAPI loopback, no extra driver). Meeting mode keeps mic and system audio as
separate tracks/files; notes mode mixes them. After a meeting summary, call
`GoogleSync.offer(notePath)` (from `../google/googleSync`).

`src/main/recording/summaryTemplates.ts`
```ts
export const SummaryTemplates: {
  readonly templatesDir: string;
  readonly activeURL: string;               // path of the active template file
  readonly activeInstructions: string;
  readonly summaryStyleInstruction: string; // NikxelSettings.summaryStyleInstruction moved here
  seedIfMissing(): void;
  available(): { slug: string; name: string }[];
  displayName(slug: string): string;
  isShipped(slug: string): boolean;
  create(name: string, copying?: string | null): string | null; // new slug, or null
  reset(slug: string): void;
  delete(slug: string): void;
  slugify(name: string): string;
  url(slug: string): string;
};
```

`src/main/recording/usageLog.ts`
```ts
export interface UsageTotals { calls: number; tokens: number; cost: number }
export const UsageLog: {
  readonly directory: string;
  record(kind: string, agentJsonOutput: string): void;
  totals(day: Date): Record<string, UsageTotals>;
  dailyAverage(): { avg: UsageTotals; days: number };
  line(t: UsageTotals): string;
};
```

`src/main/recording/transcriber.ts` (also used by the setup wizard)
```ts
export class Transcriber { findBinary(): string | null; /* + transcribe(...) */ }
export function ffmpegPath(): string | null;            // bundled ffmpeg-static, else PATH
export function hasModel(): boolean;
export function modelPath(): string;                    // ~/.nikxel/models/ggml-small.bin
export function downloadModel(progress: (msg: string, frac?: number) => void): Promise<void>;
export function installWhisper(progress: (msg: string, frac?: number) => void): Promise<void>;
```
No Homebrew on Windows: `installWhisper` downloads the official whisper.cpp
Windows release zip from GitHub into `~/.nikxel/bin/whisper/` and extracts it
(PowerShell `Expand-Archive`); `findBinary` looks there first, then PATH
(`whisper-cli`, `whisper`).

## Group C: Google (GoogleAuth, GoogleCalendarWatcher, GoogleSync, ReminderWatcher)

`src/main/google/googleAuth.ts`
```ts
export class GoogleAuth {
  static readonly shared: GoogleAuth;
  readonly isAuthorized: boolean;
  readonly isOneClick: boolean;
  onAuthorized: (() => void) | null;
  hasScope(scope: string): boolean;
  getAccessToken(): Promise<string>;   // withAccessToken; rejects when not connected / refresh failed
  invalidateAccessToken(): void;
  reauthenticate(): void;              // runs the connect flow (system browser + loopback redirect)
  start(): void;
  stop(): void;
  showAlert(message: string): void;
}
```

`src/main/google/googleCalendarWatcher.ts`
```ts
export class GoogleCalendarWatcher {
  constructor(sm: StateMachine);
  onReminder: ((text: string) => void) | null;
  start(): void; stop(): void; reauthenticate(): void;
}
```

`src/main/google/googleSync.ts`: export `GoogleSync` with the same members
as the Swift enum (`offer(notePath)`, `section`, `parseActionItems`,
`createChatTask`, `createChatMeet`, `moveChatMeet`, `deleteChatMeet`,
`onChatTaskBlocked`). Keep the Swift parameter names and order; completion
handlers become Promises. Export the block type as
`export type ChatTaskBlock = { kind: "needsReconnect" } | { kind: "apiDisabled"; url: string | null } | { kind: "other"; reason: string }`.

`src/main/google/reminderWatcher.ts`
```ts
export class ReminderWatcher {
  onReminder: ((r: { id: string; title: string }) => void) | null;
  start(): void; stop(): void;
  complete(id: string): void;
  reauthenticate(): void;
}
```
Windows has no Apple Reminders. This watches **Google Tasks** instead (the
closest thing a Windows user jots into from their phone), with the same
behaviour: persistent "seen" set, silent catch-up on first run, refetch on
`bus` `wake`, tap completes the task.

## Group D: WhatsApp & meetings (CDPClient, ChromeWhatsApp, WhatsAppNavigator, WhatsAppParser, WhatsAppSender, WhatsAppActivityLogger, WAContactLists, ChatbotEngine, LLMResponder, Devanagari, MeetingDetector)

WhatsApp Web runs in Nikxel's own hidden Electron `BrowserWindow` with
`partition: "persist:whatsapp"` and a desktop-Chrome user agent, not an
external Chrome. Where the Swift drove Chrome over CDP, use
`webContents.debugger` (same protocol) or `webContents.executeJavaScript`.
`activate()` shows and focuses that window. This removes the "install a
Chromium browser" requirement.

`src/main/whatsapp/chromeWhatsApp.ts`
```ts
export const ChromeWhatsApp: {
  activate(): void;
  openForLogin(): Promise<void>;     // shows the window at web.whatsapp.com for the QR scan
  isLoggedIn(): Promise<boolean>;
  /* + the members ChatbotEngine/ActivityLogger use, as in the Swift */
};
```

`src/main/whatsapp/chatbotEngine.ts`
```ts
export interface Delivered { contact: string; text: string; task: string | null }
export class ChatbotEngine {
  static readonly shared: ChatbotEngine;
  isEnabled: boolean;                // persisted in Settings.botEnabled
  onRepliesSent: ((batch: Delivered[], drafted: boolean) => void) | null;
  applyModeChange(): void;
  start(momGen: MOMGenerator): void;
  stop(): void;
}
```

`src/main/whatsapp/meetingDetector.ts`
```ts
export class MeetingDetector {
  static readonly shared: MeetingDetector;
  readonly isInMeeting: boolean;
  manualOverride: boolean;
  start(): void; stop(): void;       // emits bus "meetingStateChanged"
}
```

`src/main/whatsapp/whatsAppActivityLogger.ts`
```ts
export class WhatsAppActivityLogger {
  static readonly shared: WhatsAppActivityLogger;
  static readLog(file: "chats" | "calls", day: Date): any[];
  start(): void; stop(): void;
}
```

`src/main/whatsapp/waContactLists.ts`
```ts
export const WAContactLists: { seedIfMissing(kind: "trusted" | "neverReply"): string; /* + names, matches, contains */ };
```

## Group E: system (OpenCodeMonitor → AgentMonitor, DayLogger, Updater, SupportLogs, SpriteSheetImporter, OnboardingWindow, Permissions)

`src/main/system/agentMonitor.ts`
```ts
export class AgentMonitor { constructor(sm: StateMachine); startMonitoring(): void; stopMonitoring(): void; }
```

`src/main/system/dayLogger.ts`
```ts
export class DayLogger {
  static current: DayLogger | null;
  static recentSummaries(days: number): string;   // as in Swift
  constructor(momGen: MOMGenerator);
  onSummaryReady: ((line: string, filePath: string) => void) | null;
  start(): void; stop(): void;
  backfillIfMissed(): void;
  generateSummaryNow(): void;
  liveContext(inMeeting: boolean): string;
}
```
Foreground app + window title via Win32 (`GetForegroundWindow`,
`GetWindowTextW`, `GetWindowThreadProcessId`, `QueryFullProcessImageNameW`),
e.g. through a long-lived PowerShell helper reading lines from stdin, so the
15 s sampler doesn't start a process each tick.

`src/main/system/updater.ts`
```ts
export interface UpdateStatus { repo: string; isUpToDate: boolean; currentCommit: string; behind: number; branch: string; dirty: boolean; canAutoUpdate: boolean; subjects: string[] }
export class UpdateError extends Error { readonly noFolderAccess?: string }
export const Updater: {
  readonly logPath: string;
  readonly repoRoot: string | null;
  check(): Promise<UpdateStatus>;            // rejects with UpdateError
  updateAndRestart(repo: string): boolean;   // writes + launches the update script; caller then quits
  shortSubject(s: string): string;
};
```
Same model as the Mac: running from a git clone, fetch `origin/main`, then a
detached PowerShell script waits for Nikxel to exit, pulls, runs
`npm ci && npm run build` in `windows/`, rolls back on failure, relaunches.

`src/main/system/supportLogs.ts`: `export const SupportLogs: { report(): Promise<string> }`

`src/main/system/spriteSheetImporter.ts`:
`export const SpriteSheetImporter: { process(file: string): Promise<Buffer> }`
(PNG bytes; use Electron `nativeImage` for pixel access).

`src/main/system/onboarding.ts`
```ts
export class OnboardingWindowController { constructor(momGen: MOMGenerator); show(): void; }
```
Same four steps. Transcription step uses `installWhisper` / `downloadModel` /
`ffmpegPath` from `../recording/transcriber`; WhatsApp step uses
`ChromeWhatsApp.openForLogin()` / `isLoggedIn()`; agent step uses
`momGen.checkAgent` and `AGENT_INFO[agent].installCommand`.

`src/main/system/permissions.ts`: `export const Permissions: { offer(): void }`.
Windows needs no Accessibility or Screen Recording grant; the one that can be
off is microphone privacy (`systemPreferences.getMediaAccessStatus("microphone")`,
`ms-settings:privacy-microphone`).
