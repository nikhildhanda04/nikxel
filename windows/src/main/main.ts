import { app, clipboard, dialog, Menu, MenuItemConstructorOptions, nativeImage, powerMonitor, shell, Tray } from "electron";
import * as fs from "fs";
import * as path from "path";
import { bus } from "./core/bus";
import { cblog } from "./core/diag";
import { openFile, openFolder, openUrl } from "./core/open";
import { documentsDir, nikxelPath, resourcePath } from "./core/paths";
import { promptText } from "./core/prompt";
import {
  CAPTURE_MODE_NAMES, NOTE_FORMATS, NOTE_FORMAT_INFO, Settings, Sprites, WA_BOT_MODES, WA_BOT_MODE_NAMES,
} from "./core/settings";
import { StateMachine } from "./core/stateMachine";
import { CardKind, ui } from "./core/ui";
import { createAvatarWindow } from "./avatar/avatarWindow";
import { InputHandler } from "./avatar/inputHandler";
import { GoogleCalendarWatcher } from "./google/googleCalendarWatcher";
import { ChatTaskBlock, GoogleSync } from "./google/googleSync";
import { ReminderWatcher } from "./google/reminderWatcher";
import { MeetingCoordinator } from "./recording/meetingCoordinator";
import { PendingJob } from "./recording/momGenerator";
import { SummaryTemplates } from "./recording/summaryTemplates";
import { UsageLog, UsageTotals } from "./recording/usageLog";
import { AgentMonitor } from "./system/agentMonitor";
import { DayLogger } from "./system/dayLogger";
import { OnboardingWindowController } from "./system/onboarding";
import { Permissions } from "./system/permissions";
import { SupportLogs } from "./system/supportLogs";
import { UpdateError, UpdateStatus, Updater } from "./system/updater";
import { ChatbotEngine, Delivered } from "./whatsapp/chatbotEngine";
import { ChromeWhatsApp } from "./whatsapp/chromeWhatsApp";
import { MeetingDetector } from "./whatsapp/meetingDetector";
import { WAContactLists } from "./whatsapp/waContactLists";
import { WhatsAppActivityLogger } from "./whatsapp/whatsAppActivityLogger";

/// Port of NikxelApp.swift: starts every watcher, owns the tray menu (the Mac
/// menu-bar item), and routes events between modules and the avatar.

// One Nikxel at a time: a second launch (Start menu while it's already in the
// tray) just brings the avatar back.
if (!app.requestSingleInstanceLock()) {
  app.quit();
} else {
  app.on("second-instance", () => nikxel?.showAvatar());
  app.setAppUserModelId("com.nikxel.Nikxel");
  app.whenReady().then(() => { nikxel = new NikxelApp(); nikxel.launch(); });
  // The avatar window is the app; closing every other window must not quit.
  app.on("window-all-closed", () => { /* stay in the tray */ });
  app.on("before-quit", () => nikxel?.terminate());
}

let nikxel: NikxelApp | null = null;

class NikxelApp {
  private stateMachine = new StateMachine();
  private avatar!: ReturnType<typeof createAvatarWindow>;
  private tray!: Tray;
  private agentMonitor!: AgentMonitor;
  private inputHandler!: InputHandler;
  private calendarWatcher!: GoogleCalendarWatcher;
  private reminderWatcher!: ReminderWatcher;
  private meetingCoordinator!: MeetingCoordinator;
  private dayLogger!: DayLogger;
  private meetingDetector!: MeetingDetector;
  private chatbotEngine!: ChatbotEngine;
  private whatsAppActivityLogger!: WhatsAppActivityLogger;
  private onboarding: OnboardingWindowController | null = null;
  private reminderDismissTimer?: NodeJS.Timeout;
  private checkingForUpdates = false;
  private terminated = false;

  launch(): void {
    const sm = this.stateMachine;
    this.agentMonitor = new AgentMonitor(sm);

    this.meetingCoordinator = new MeetingCoordinator(sm);
    this.avatar = createAvatarWindow(sm, {
      onDoubleClick: () => this.meetingCoordinator.toggleRecording(false),
    });
    this.inputHandler = new InputHandler(sm, () => this.avatar.recordKeystroke());
    // Puff BEFORE the window shows, so the first frame already has the avatar
    // hidden and dust forming rather than a flash of Nikxel.
    this.avatar.triggerPuff();
    this.avatar.show();

    this.calendarWatcher = new GoogleCalendarWatcher(sm);
    this.calendarWatcher.onReminder = text => this.showReminder(text);

    this.reminderWatcher = new ReminderWatcher();
    this.reminderWatcher.onReminder = r => ui.pushReminder(r.id, r.title);
    ui.onReminderTapped(id => this.reminderWatcher.complete(id));

    this.dayLogger = new DayLogger(this.meetingCoordinator.momGen);
    this.dayLogger.onSummaryReady = (line, filePath) => {
      // Ten minutes: this fires at 10pm, so it has to survive the user being
      // away from the PC when it lands.
      ui.showCard({
        icon: "🌙", title: "Today, in short", lines: [line],
        kind: "info", lifetime: 600, action: () => openFile(filePath),
      });
    };

    this.meetingDetector = MeetingDetector.shared;
    this.chatbotEngine = ChatbotEngine.shared;
    this.chatbotEngine.onRepliesSent = (batch, drafted) => this.showReplyCard(batch, drafted);
    GoogleSync.onChatTaskBlocked = block => this.showChatTaskBlocked(block);
    this.whatsAppActivityLogger = WhatsAppActivityLogger.shared;

    bus.on("activeTexterChanged", name => ui.setActiveTexter(name));
    bus.on("meetingStateChanged", inMeeting => {
      cblog(`NikxelApp: handleMeetingStateChanged → isInMeeting=${inMeeting}`);
      ui.setInMeeting(inMeeting);
    });

    SummaryTemplates.seedIfMissing();
    this.setupTray();
    this.agentMonitor.startMonitoring();
    this.inputHandler.startMonitoring();
    this.calendarWatcher.start();
    this.reminderWatcher.start();
    this.dayLogger.start();
    this.meetingDetector.start();
    this.chatbotEngine.start(this.meetingCoordinator.momGen);
    this.whatsAppActivityLogger.start();
    cblog("NikxelApp: didFinishLaunching — detectors started");

    // Timers don't fire while the PC sleeps, so the 22:00 summary can silently
    // miss. On wake, everything that cares re-checks (the day logger backfills,
    // the reminder watcher refetches).
    const wake = () => setImmediate(() => bus.emit("wake"));
    powerMonitor.on("resume", wake);
    powerMonitor.on("unlock-screen", wake);
    bus.on("wake", () => this.dayLogger.backfillIfMissed());

    // Ask for the microphone up front so it's settled before the user records.
    this.meetingCoordinator.recorder.warmUpPermission();

    if (!Settings.onboardingCompleted) {
      this.showOnboarding();
    } else {
      // After the avatar's puff, so the bubble has somewhere to land.
      setTimeout(() => Permissions.offer(), 4000);
    }

    // Start at login, once: a user who restarts shouldn't have to hunt for
    // Nikxel. Once only, so turning it off in Settings → Apps → Startup sticks.
    if (!Settings.loginItemOffered) {
      Settings.loginItemOffered = true;
      try {
        app.setLoginItemSettings(app.isPackaged
          ? { openAtLogin: true }
          : { openAtLogin: true, path: process.execPath, args: [app.getAppPath()] });
      } catch (e) { cblog(`NikxelApp: login item failed — ${e}`); }
    }

    ensureStartMenuShortcut();

    // A summary interrupted by a quit or crash leaves its marker behind.
    const unfinished = this.meetingCoordinator.momGen.unfinishedJobs();
    if (unfinished.length) {
      ui.pushReminder("nikxel.unfinished",
        `${unfinished.length} summar${unfinished.length === 1 ? "y" : "ies"} unfinished — see the tray menu`);
    }
  }

  showAvatar(): void {
    if (!this.avatar.isVisible()) { this.avatar.triggerPuff(); this.avatar.show(); }
  }

  private showOnboarding(): void {
    if (!this.onboarding) this.onboarding = new OnboardingWindowController(this.meetingCoordinator.momGen);
    this.onboarding.show();
  }

  terminate(): void {
    if (this.terminated) return;
    this.terminated = true;
    this.agentMonitor?.stopMonitoring();
    this.inputHandler?.stopMonitoring();
    this.calendarWatcher?.stop();
    this.reminderWatcher?.stop();
    this.dayLogger?.stop();
    this.meetingDetector?.stop();
    this.chatbotEngine?.stop();
    this.whatsAppActivityLogger?.stop();
  }

  // MARK: - Tray

  /// The avatar head on a light plate, as the Mac's AppIcon. The plate keeps
  /// it readable on dark and light taskbars, which a template image isn't.
  private trayIcon(): Electron.NativeImage {
    return nativeImage.createFromPath(resourcePath("tray.png")).resize({ width: 32, height: 32, quality: "good" });
  }

  private setupTray(): void {
    this.tray = new Tray(this.trayIcon());
    this.tray.setToolTip("Nikxel");
    // Built fresh on every open, so every check mark and the AI usage numbers
    // are current — the Mac app refreshed items as settings changed instead.
    const pop = () => this.tray.popUpContextMenu(this.buildMenu());
    this.tray.on("click", pop);
    this.tray.on("right-click", pop);
  }

  private buildMenu(): Menu {
    const mode = Settings.captureMode;
    const recorder = this.meetingCoordinator.recorder;
    const forced = this.meetingDetector.manualOverride;
    const item = (label: string, click: () => void, extra: Partial<MenuItemConstructorOptions> = {}): MenuItemConstructorOptions =>
      ({ label, click, ...extra });
    const check = (label: string, checked: boolean, click: () => void): MenuItemConstructorOptions =>
      ({ label, type: "checkbox", checked, click });
    const radio = (label: string, checked: boolean, click: () => void): MenuItemConstructorOptions =>
      ({ label, type: "radio", checked, click });
    const header = (label: string): MenuItemConstructorOptions => ({ label, enabled: false });
    const sep: MenuItemConstructorOptions = { type: "separator" };

    const quiet = Settings.waQuietHours;
    const whatsapp: MenuItemConstructorOptions[] = [
      check(this.chatbotEngine.isEnabled ? "Auto-Replies: On" : "Auto-Replies: Off", this.chatbotEngine.isEnabled,
        () => { this.chatbotEngine.isEnabled = !this.chatbotEngine.isEnabled; }),
      sep,
      header("Reply…"),
      ...WA_BOT_MODES.map(m => radio(
        // Only the unattended mode has a delay to name, and it's edited in
        // settings.json rather than here.
        m === "unattended" ? `Any time, if unanswered for ${Settings.waUnattendedMinutes} min` : WA_BOT_MODE_NAMES[m],
        Settings.waBotMode === m,
        () => { Settings.waBotMode = m; this.chatbotEngine.applyModeChange(); })),
      sep,
      check(Settings.waGroupReplies ? "Group Chats: Only When Tagged" : "Group Chats: Off", Settings.waGroupReplies,
        () => { Settings.waGroupReplies = !Settings.waGroupReplies; }),
      check(`Draft Only (don't send): ${Settings.waDraftOnly ? "On" : "Off"}`, Settings.waDraftOnly,
        () => { Settings.waDraftOnly = !Settings.waDraftOnly; }),
      check(quiet ? `Quiet Hours: ${hourLabel(Settings.waQuietFrom)}–${hourLabel(Settings.waQuietTo)}` : "Quiet Hours: Off", quiet,
        () => { Settings.waQuietHours = !Settings.waQuietHours; }),
      check(`Knows What You're Working On: ${Settings.waWorkContext ? "On" : "Off"}`, Settings.waWorkContext,
        () => { Settings.waWorkContext = !Settings.waWorkContext; }),
      check(`Tasks from Chats: ${Settings.waChatTasks ? "On" : "Off"}`, Settings.waChatTasks,
        () => { Settings.waChatTasks = !Settings.waChatTasks; }),
      sep,
      item("Open WhatsApp Window", () => ChromeWhatsApp.activate()),
      item("Edit Bot Personality…", () => this.editBotPersonality()),
      item("Edit Trusted Contacts…", () => openFile(WAContactLists.seedIfMissing("trusted"))),
      item("Edit Never-Reply List…", () => openFile(WAContactLists.seedIfMissing("neverReply"))),
    ];

    const sizes: [string, number][] = [["Small", 0.6], ["Medium", 0.8], ["Large", 1.0], ["Extra Large", 1.25]];

    const template: MenuItemConstructorOptions[] = [
      item(this.avatar.isVisible() ? "Hide Nikxel" : "Show Nikxel", () => this.toggleVisibility()),
      // The tray is the deliberate path, so it isn't blocked while a summary
      // is still being written.
      item(`Start/Stop Recording (${CAPTURE_MODE_NAMES[mode]})`, () => this.meetingCoordinator.toggleRecording(true)),
      check(forced ? "Stop Forcing Meeting Mode" : "Force Meeting Mode (offline)", forced, () => {
        this.meetingDetector.manualOverride = !this.meetingDetector.manualOverride;
        cblog(`NikxelApp: toggleForceMeeting → manualOverride=${this.meetingDetector.manualOverride}, isInMeeting=${this.meetingDetector.isInMeeting}`);
      }),
      check(recorder.isMicMuted ? "Unmute Mic" : "Mute Mic", recorder.isMicMuted,
        () => { recorder.isMicMuted = !recorder.isMicMuted; }),
      { label: "WhatsApp Bot", submenu: whatsapp },
      { label: "Capture Mode", submenu: [
        radio("Notes (videos, lectures, podcasts)", mode === "notes", () => { Settings.captureMode = "notes"; }),
        radio("Meeting (per-speaker)", mode === "meeting", () => { Settings.captureMode = "meeting"; }),
      ] },
      { label: "Note Format", submenu: NOTE_FORMATS.map(f =>
        radio(NOTE_FORMAT_INFO[f].displayName, Settings.noteFormat === f, () => { Settings.noteFormat = f; })) },
      { label: "Avatar Size", submenu: sizes.map(([label, size]) =>
        radio(label, Math.abs(Settings.avatarSize - size) < 0.01, () => {
          Settings.avatarSize = size;
          this.avatar.applyAvatarSize();
        })) },
      item("Open Notes Folder", () => openFolder(documentsDir("notes"))),
      item("Open Meetings Folder", () => openFolder(documentsDir("meetings"))),
      item("Open Daily Summaries Folder", () => openFolder(documentsDir("daily"))),
      item("Summarize Today Now", () => this.dayLogger.generateSummaryNow()),
      { label: "AI Usage", submenu: this.usageMenu() },
      item("Connect Google Account…", () => this.calendarWatcher.reauthenticate()),
      check(`Send Meeting Tasks to Google: ${Settings.googleSyncEnabled ? "On" : "Off"}`, Settings.googleSyncEnabled,
        () => { Settings.googleSyncEnabled = !Settings.googleSyncEnabled; }),
      // Apple Reminders on the Mac. Windows has none, so new Google Tasks
      // (added from a phone, Gmail, Calendar) bubble up instead.
      item("Connect Google Tasks Reminders…", () => this.reminderWatcher.reauthenticate()),
      { label: "Summary Template", submenu: this.templateMenu() },
      item("Edit Nikxel Settings (name, language)…", () => this.editSettings()),
      item("Regenerate Unfinished Summary…", () => this.regenerateUnfinished()),
      item("Setup Wizard…", () => this.showOnboarding()),
      item("Copy Logs (to share when something breaks)", () => this.copyLogs()),
      item(this.checkingForUpdates ? "Checking for Updates…" : "Check for Updates…", () => this.checkForUpdates(),
        { enabled: !this.checkingForUpdates }),
      sep,
      item("Quit Nikxel", () => app.quit()),
    ];
    return Menu.buildFromTemplate(template);
  }

  private toggleVisibility(): void {
    if (this.avatar.isVisible()) this.avatar.hide();
    else this.showAvatar();
  }

  private usageMenu(): MenuItemConstructorOptions[] {
    const info = (label: string): MenuItemConstructorOptions => ({ label, enabled: false });
    const today = UsageLog.totals(new Date());
    const all: UsageTotals = { calls: 0, tokens: 0, cost: 0 };
    for (const t of Object.values(today)) { all.calls += t.calls; all.tokens += t.tokens; all.cost += t.cost; }
    const items = [info("Today: " + UsageLog.line(all))];
    for (const [kind, t] of Object.entries(today).sort((a, b) => b[1].cost - a[1].cost)) {
      items.push(info(`    ${kind}: ` + UsageLog.line(t)));
    }
    const { avg, days } = UsageLog.dailyAverage();
    items.push(info(days === 0 ? "Daily average: no history yet"
      : `Daily average (last ${days} day${days === 1 ? "" : "s"}): ` + UsageLog.line(avg)));
    items.push({ type: "separator" }, { label: "Open Usage Log Folder", click: () => openFolder(UsageLog.directory) });
    return items;
  }

  // MARK: - Summary templates

  private templateMenu(): MenuItemConstructorOptions[] {
    const active = Settings.summaryTemplate;
    const activeName = SummaryTemplates.displayName(active);
    const items: MenuItemConstructorOptions[] = SummaryTemplates.available().map(t => ({
      label: t.name, type: "radio", checked: t.slug === active,
      click: () => { Settings.summaryTemplate = t.slug; },
    }));
    items.push(
      { type: "separator" },
      { label: `Edit “${activeName}”…`, click: () => this.editActiveTemplate() },
      { label: "New Template…", click: () => this.newTemplate() },
      SummaryTemplates.isShipped(active)
        ? { label: `Reset “${activeName}” to Default…`, click: () => this.resetActiveTemplate() }
        : { label: `Delete “${activeName}”…`, click: () => this.deleteActiveTemplate() },
      { label: "Open Templates Folder", click: () => openFolder(SummaryTemplates.templatesDir) },
    );
    return items;
  }

  private async editActiveTemplate(): Promise<void> {
    const slug = Settings.summaryTemplate;
    const r = await dialog.showMessageBox({
      type: "info",
      title: "Nikxel",
      message: `Editing “${SummaryTemplates.displayName(slug)}”`,
      detail: "Write plain instructions, one per line — the same way you'd tell a person. They're added to the prompt your coding agent runs and override the built-in structure: drop a section you don't use, add one you do, change the order, set the length or the tone.\n\n" +
        "Lines starting with # are ignored, so the notes already in the file are safe to leave there.\n\n" +
        "Takes effect on your next recording. Nikxel still won't invent content to satisfy an instruction — attendees, decisions, owners, numbers and dates come only from the transcript.",
      buttons: [`Open ${slug}.txt`, "Cancel"],
      defaultId: 0, cancelId: 1, noLink: true,
    });
    if (r.response === 0) openFile(SummaryTemplates.activeURL);
  }

  private async newTemplate(): Promise<void> {
    const active = Settings.summaryTemplate;
    const r = await promptText({
      title: "New summary template",
      message: "Name it after the kind of meeting or the role it's for — \"Client Calls\", \"Design Review\", \"Board\".",
      placeholder: "Template name",
      buttons: ["Create, starting blank", `Create, copying “${SummaryTemplates.displayName(active)}”`, "Cancel"],
    });
    if (r.button !== 0 && r.button !== 1) return;
    const slug = SummaryTemplates.create(r.value, r.button === 1 ? active : null);
    if (!slug) {
      ui.tell({
        icon: "⚠️", title: "Couldn't create that template", kind: "warning",
        lines: [SummaryTemplates.slugify(r.value) === ""
          ? "Give it a name with at least one letter or number in it."
          : "A template with that name already exists. Pick a different name, or edit the existing one."],
      });
      return;
    }
    Settings.summaryTemplate = slug;
    openFile(SummaryTemplates.url(slug));
  }

  private resetActiveTemplate(): void {
    const slug = Settings.summaryTemplate;
    ui.ask({
      title: `Reset “${SummaryTemplates.displayName(slug)}” to the built-in version?`,
      lines: [`Anything you've written in ${slug}.txt will be replaced. Your other templates aren't touched.`],
      kind: "warning",
      buttons: [{ title: "Reset", action: () => SummaryTemplates.reset(slug) }, { title: "Cancel", action: () => {} }],
    });
  }

  private deleteActiveTemplate(): void {
    const slug = Settings.summaryTemplate;
    ui.ask({
      title: `Delete “${SummaryTemplates.displayName(slug)}”?`,
      lines: [`${slug}.txt is removed and summaries go back to the Default template.`],
      kind: "warning",
      buttons: [{ title: "Delete", action: () => SummaryTemplates.delete(slug) }, { title: "Cancel", action: () => {} }],
    });
  }

  // MARK: - Settings files

  private editBotPersonality(): void {
    const file = nikxelPath("bot_personality.txt");
    // Seed a default so the editor opens with something useful.
    if (!fs.existsSync(file)) {
      const name = Settings.userName;
      fs.writeFileSync(file, `You are ${name}'s friendly AI assistant. You're responding to WhatsApp messages while ${name} is in a meeting. Be casual, warm, and helpful. Keep responses concise (1-3 sentences). Be honest -- say you're ${name}'s assistant, don't pretend to be them.\n`);
    }
    openFile(file);
  }

  private async editSettings(): Promise<void> {
    const file = nikxelPath("settings.json");
    if (!fs.existsSync(file)) {
      fs.writeFileSync(file, JSON.stringify({
        userName: Settings.userName,
        waOwnName: Settings.waOwnName,
        language: "auto",
        botMemoryDays: Settings.botMemoryDays,
        waUnattendedMinutes: Settings.waUnattendedMinutes,
        googleSyncEnabled: Settings.googleSyncEnabled,
      }, null, 2));
    }
    await dialog.showMessageBox({
      type: "info",
      title: "Nikxel",
      message: "Nikxel Settings",
      detail: [
        "userName — your real name, used so meeting MOMs correctly identify \"Me\" as you (not whoever else gets mentioned on the call).",
        "waOwnName — your name exactly as it shows in your own WhatsApp account (often your full name) — used to filter your own messages out of chat scraping. Leave as-is if unsure.",
        "language — \"auto\" to match whichever language the content is in (English, Hindi, Hinglish, etc.), or a specific language name (e.g. \"Hindi\") to always force it.",
        "botMemoryDays — how many days of your end-of-day summaries the WhatsApp bot reads before replying, so it recognises what someone is asking about. It is told never to disclose from them. 0 turns it off; 7 is the default.",
        "summaryTemplate — which template in ~/.nikxel/templates/ shapes your summaries (developer, hr, project-manager, co-founder, default, or one you made). Pick it from the Summary Template menu instead of editing this by hand.",
        "waUnattendedMinutes — in \"Any time, if unanswered\" mode, how many minutes a message must sit unread before the bot answers it. 5 is the default.",
        "waQuietFrom / waQuietTo — the hours (0-23) quiet hours run between; 22 and 8 by default. Turn them on or off from the WhatsApp Bot menu.",
        "projectsRoot — the folder scanned for git repos, so day summaries and the WhatsApp bot know what you have been building. Defaults to ~/Desktop; point it at your actual projects folder and the scan is both faster and more accurate.",
        "googleSyncEnabled — whether a finished meeting summary offers to add its Action Items to Google Tasks and its follow-ups to your calendar. Nothing is ever added without you confirming the list first.",
      ].join("\n\n"),
      buttons: ["Open settings.json"],
      noLink: true,
    });
    openFile(file);
  }

  // MARK: - Recovery

  /// Offers to re-run the newest summary that was started but never written,
  /// from the transcript saved before generation.
  private regenerateUnfinished(): void {
    const jobs = this.meetingCoordinator.momGen.unfinishedJobs();
    const job = jobs[0];
    if (!job) {
      ui.tell({ title: "Nothing to regenerate", lines: ["Every recording you've made has a summary."] });
      return;
    }
    const when = job.startedAt.toLocaleString(undefined, { dateStyle: "medium", timeStyle: "short" });
    ui.ask({
      icon: "🔁", title: "Regenerate this summary?",
      lines: [
        `${job.mode === "notes" ? "Notes" : "Meeting"} from ${when}.`,
        "The transcript is saved — this re-runs your coding agent over it.",
        ...(jobs.length > 1 ? [`${jobs.length - 1} more unfinished after this one.`] : []),
      ],
      buttons: [{ title: "Regenerate", action: () => this.regenerate(job) }, { title: "Cancel", action: () => {} }],
    });
  }

  private async regenerate(job: PendingJob): Promise<void> {
    this.stateMachine.startWritingMOM();
    try {
      const notePath = await this.meetingCoordinator.momGen.regenerate(job);
      this.stateMachine.endWritingMOM();
      this.stateMachine.triggerMomReady();
      openFile(notePath);
      if (job.mode === "meeting") GoogleSync.offer(notePath);
    } catch (e) {
      this.stateMachine.endWritingMOM();
      ui.tell({ icon: "⚠️", title: "Regeneration failed", lines: [String((e as Error)?.message ?? e).slice(0, 160)],
        kind: "error", lifetime: Infinity });
    }
  }

  private async copyLogs(): Promise<void> {
    const text = await SupportLogs.report();
    clipboard.writeText(text);
    ui.tell({ icon: "📋", title: "Logs copied", lines: ["Paste them into WhatsApp (Ctrl+V) and send."], kind: "success", lifetime: 8 });
  }

  // MARK: - Updates

  private async checkForUpdates(): Promise<void> {
    if (this.checkingForUpdates) return;
    this.checkingForUpdates = true;
    try {
      this.presentUpdate(await Updater.check());
    } catch (e) {
      const err = e as UpdateError;
      this.presentCard({
        icon: "⚠️", title: "Couldn't check for updates",
        lines: String(err?.message ?? e).split("\n\n").map(s => s.replace(/\n/g, " ")).filter(Boolean),
        kind: "warning", lifetime: 30,
        action: err?.noFolderAccess ? () => this.checkForUpdates() : undefined,
      });
    } finally {
      this.checkingForUpdates = false;
    }
  }

  private presentUpdate(status: UpdateStatus): void {
    if (status.isUpToDate) {
      this.presentCard({ icon: "✅", title: "Nikxel is up to date",
        lines: [`You're on the latest version (${status.currentCommit}).`], kind: "success", lifetime: 8 });
      return;
    }
    const n = status.behind;
    const title = n === 1 ? "1 update available" : `${n} updates available`;

    // A fast-forward pull needs main and a clean tree. Say which one is in the
    // way rather than letting the update script discover it and roll back.
    if (!status.canAutoUpdate) {
      const why: string[] = [];
      if (status.branch !== "main") why.push(`You're on the "${status.branch}" branch, not main.`);
      if (status.dirty) why.push("You have uncommitted changes, which would block the pull.");
      why.push("Fix that, then check again.");
      this.presentCard({ icon: "⚠️", title, lines: why, kind: "warning", lifetime: 30 });
      return;
    }

    // The card carries one action, so tapping IS the confirmation — hence
    // spelling out that it restarts. Ignoring it fades it.
    const lines = status.subjects.slice(0, 3).map(s => Updater.shortSubject(s));
    if (status.subjects.length > 3) lines.push(`…and ${status.subjects.length - 3} more`);
    lines.push("Tap to update and restart.");
    this.presentCard({ icon: "⬇️", title, lines, bulleted: true, kind: "info", lifetime: 45,
      action: () => this.startUpdate(status) });
  }

  private startUpdate(status: UpdateStatus): void {
    if (!Updater.updateAndRestart(status.repo)) {
      this.presentCard({ icon: "⚠️", title: "Couldn't start the update",
        lines: ["Nikxel couldn't write its update script.", "Tap to open the update log."],
        kind: "error", lifetime: Infinity, action: () => openFile(Updater.logPath) });
      return;
    }
    // The script waits for this process to exit before it touches anything,
    // so quitting IS the next step.
    this.presentCard({ icon: "⬇️", title: "Updating…",
      lines: ["Nikxel will quit, rebuild and come back in a moment."], kind: "info", lifetime: 10 });
    setTimeout(() => app.quit(), 1400);
  }

  /// A card, with the avatar brought back if it was hidden. Update feedback is
  /// asked for from the tray, so it has to appear even with no avatar showing.
  private presentCard(c: { icon: string; title: string; lines: string[]; bulleted?: boolean; kind: CardKind;
    lifetime: number; action?: () => void }): void {
    ui.showCard(c, { forceVisible: true });
  }

  // MARK: - Bubbles

  private showChatTaskBlocked(block: ChatTaskBlock): void {
    switch (block.kind) {
      case "needsReconnect":
        ui.showCard({ icon: "🔑", title: "Reconnect Google to file tasks",
          lines: ["Your account was connected before Nikxel could write to Tasks.",
            "Tap to reconnect — one click, nothing else changes."],
          kind: "warning", lifetime: Infinity, action: () => this.calendarWatcher.reauthenticate() });
        break;
      case "apiDisabled": {
        const url = block.url;
        ui.showCard({ icon: "🔧", title: "Turn on the Google Tasks API",
          lines: ["Your Google project hasn't enabled Tasks, so nothing can be filed.",
            url ? "Tap to open the page that switches it on." : "Enable it in the Google Cloud console."],
          kind: "warning", lifetime: Infinity, action: url ? () => openUrl(url) : undefined });
        break;
      }
      case "other":
        ui.showCard({ icon: "⚠️", title: "Couldn't file a task from a chat",
          lines: [block.reason.slice(0, 160)], kind: "warning", lifetime: 30 });
        break;
    }
  }

  /// Bubble after the bot has been round a batch of chats. Drafts get a sterner
  /// card than sent replies: a draft is unfinished business sitting in a chat,
  /// so it stays until clicked and clicking opens the WhatsApp window.
  private showReplyCard(batch: Delivered[], drafted: boolean): void {
    if (!batch.length) return;
    const lines = batch.slice(0, 3).map(d => {
      const snippet = d.text.replace(/\n/g, " ");
      // 45 keeps a bullet to two rendered lines at the card's width.
      return `${d.contact} — ${snippet.slice(0, 45)}${snippet.length > 45 ? "…" : ""}`;
    });
    if (batch.length > 3) lines.push(`…and ${batch.length - 3} more`);
    const tasks = batch.filter(d => d.task);
    if (tasks.length) lines.push(`Added ${tasks.length} task${tasks.length === 1 ? "" : "s"} to Google Tasks`);
    ui.showCard({
      icon: drafted ? "✍️" : "💬",
      title: drafted ? `${batch.length} draft${batch.length === 1 ? "" : "s"} waiting` : "Replied for you",
      lines, bulleted: true,
      kind: drafted ? "warning" : "success",
      lifetime: drafted ? Infinity : 25,
      action: drafted ? () => ChromeWhatsApp.activate() : undefined,
    });
  }

  private showReminder(text: string): void {
    ui.setReminderText(text);
    if (this.reminderDismissTimer) clearTimeout(this.reminderDismissTimer);
    this.reminderDismissTimer = setTimeout(() => ui.setReminderText(null), 10_000);
  }
}

/// Run from a source checkout, Nikxel is electron.exe pointed at this folder.
/// A Start-menu shortcut makes it findable like any app (Start, search, pin)
/// and is what Windows needs before it shows toast notifications: the
/// shortcut carries the AppUserModelID they're attributed to. Refreshed every
/// launch in case the clone moved. The installer build makes its own.
function ensureStartMenuShortcut(): void {
  if (process.platform !== "win32" || app.isPackaged) return;
  const lnk = path.join(app.getPath("appData"), "Microsoft", "Windows", "Start Menu", "Programs", "Nikxel.lnk");
  const ok = shell.writeShortcutLink(lnk, fs.existsSync(lnk) ? "replace" : "create", {
    target: process.execPath,
    args: `"${app.getAppPath()}"`,
    cwd: app.getAppPath(),
    icon: resourcePath("icon.ico"),
    iconIndex: 0,
    appUserModelId: "com.nikxel.Nikxel",
    description: "Nikxel — your pixel desktop companion",
  });
  if (!ok) cblog("NikxelApp: couldn't write the Start menu shortcut");
}

/// 22 -> "10pm". Menu titles read better than 24h clock time here.
function hourLabel(h: number): string {
  const suffix = h < 12 ? "am" : "pm";
  const twelve = h % 12 === 0 ? 12 : h % 12;
  return `${twelve}${suffix}`;
}
