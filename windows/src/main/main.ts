import { app, clipboard, dialog, Menu, MenuItemConstructorOptions, nativeImage, powerMonitor, shell, Tray } from "electron";
import * as fs from "fs";
import * as path from "path";
import { bus } from "./core/bus";
import * as Health from "./core/health";
import { cblog } from "./core/diag";
import { openFile, openFolder, openUrl } from "./core/open";
import { documentsDir, nikxelPath, resourcePath } from "./core/paths";
import { promptText } from "./core/prompt";
import { powershell } from "./core/proc";
import { CAPTURE_MODE_NAMES, Settings } from "./core/settings";
import { StateMachine } from "./core/stateMachine";
import { CardKind, ui } from "./core/ui";
import { createAvatarWindow } from "./avatar/avatarWindow";
import * as AvatarChat from "./system/avatarChat";
import { Automations } from "./system/automations";
import * as Dashboard from "./system/dashboardWindow";
import { CoachTour, TourHost } from "./system/coachTour";
import * as Learning from "./system/learning";
import { InputHandler } from "./avatar/inputHandler";
import { GoogleCalendarWatcher } from "./google/googleCalendarWatcher";
import { ChatTaskBlock, GoogleSync } from "./google/googleSync";
import { ReminderWatcher } from "./google/reminderWatcher";
import { MeetingCoordinator } from "./recording/meetingCoordinator";
import { PendingJob } from "./recording/momGenerator";
import { SummaryTemplates } from "./recording/summaryTemplates";
import { UsageLog } from "./recording/usageLog";
import { AgentMonitor } from "./system/agentMonitor";
import { DayLogger } from "./system/dayLogger";
import * as Slack from "./system/slack";
import * as PageShare from "./system/pageShare";
import * as ERP from "./system/erp";
import { CloudSync } from "./system/cloudSync";
import * as ErpCrawl from "./system/erpCrawl";
import { showAboutMe } from "./system/aboutMe";
import { OnboardingWindowController } from "./system/onboarding";
import { Permissions } from "./system/permissions";
import { SupportLogs } from "./system/supportLogs";
import { UpdateError, UpdateStatus, Updater } from "./system/updater";
import { ChatbotEngine, Delivered } from "./whatsapp/chatbotEngine";
import { ChromeWhatsApp } from "./whatsapp/chromeWhatsApp";
import { MeetingDetector } from "./whatsapp/meetingDetector";
import { WhatsAppActivityLogger } from "./whatsapp/whatsAppActivityLogger";

/// Port of NikxelApp.swift: starts every watcher, owns the tray menu (the Mac
/// menu-bar item), and routes events between modules and the avatar.

// Chromium stops painting a window it thinks is covered (a maximised app under
// it, a locked screen), and missed the topmost, see-through avatar coming back.
app.commandLine.appendSwitch("disable-features", "CalculateNativeWinOcclusion");

// One Nikxel at a time: a second launch (Start menu while it's already in the
// tray) just brings the avatar back.
if (!app.requestSingleInstanceLock()) {
  app.quit();
} else {
  // Logging must never be what stops Nikxel starting.
  try { Health.start(); } catch (e) { console.error(e); }
  app.on("second-instance", () => nikxel?.showAvatar());
  app.setAppUserModelId("com.nikxel.Nikxel");
  app.whenReady().then(() => { nikxel = new NikxelApp(); nikxel.launch(); Health.didLaunch(); })
    .catch(e => Health.failedToStart(String(e?.stack ?? e)));
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

  /// A call or Meet just started and nothing is recording: ask once. At most every 30 min, since a
  /// Meet tab moved to the background drops out of detection and comes back as a "new" call.
  /// Port of NikxelApp.offerToRecord.
  private offerToRecord(inMeeting: boolean): void {
    if (!inMeeting) {
      // The call ended with the question still up: it's moot now.
      if (!this.meetingDetector.micApp) this.dismissRecordPrompt();
      return;
    }
    const source = this.meetingDetector.source;
    if (source) this.askToRecord("You're in " + source, Settings.autoRecordCalls, "Recording " + source);
  }

  /// Any other app took the microphone: offer to record that too, unless a
  /// call prompt already covers it. Port of NikxelApp.offerToRecord(micApp:).
  private offerToRecordMic(app: string | null): void {
    if (!app) { if (!this.meetingDetector.isInMeeting) this.dismissRecordPrompt(); return; }
    if (!this.meetingDetector.isInMeeting) this.askToRecord(`${app} is using your mic`, false);
  }

  /// When each prompt was last shown, by title, and whether one is on screen.
  private promptedAt = new Map<string, number>();
  private recordPromptUp = false;

  private dismissRecordPrompt(): void {
    if (this.recordPromptUp) this.avatar.dismissCard();
    this.recordPromptUp = false;
  }

  /// "Want me to record it?", once per call or app every 30 minutes, and never
  /// while already recording. `autoRecord`: the user agreed to this once
  /// (learning.ts offerAutoRecordCalls), so record without asking.
  private askToRecord(title: string, autoRecord: boolean, recording = "Recording"): void {
    if (this.meetingCoordinator.isRecording || Date.now() - (this.promptedAt.get(title) ?? 0) < 30 * 60_000) return;
    this.promptedAt.set(title, Date.now());
    if (autoRecord) {
      this.meetingCoordinator.toggleRecording(false);
      ui.tell({ icon: "🎙️", title: recording, lines: ["Double-click me to stop."] });
      return;
    }
    this.recordPromptUp = true;
    ui.ask({ icon: "🎙️", title, lines: ["Want me to record it and write the notes?"], buttons: [
      { title: "Record", action: () => {
        this.recordPromptUp = false;
        Learning.count("call.record");
        if (!this.meetingCoordinator.isRecording) this.meetingCoordinator.toggleRecording(false);
      } },
      { title: "Not now", action: () => { this.recordPromptUp = false; Learning.count("call.skip"); } },
    ] });
  }


  launch(): void {
    const sm = this.stateMachine;
    this.agentMonitor = new AgentMonitor(sm);

    this.meetingCoordinator = new MeetingCoordinator(sm);
    this.avatar = createAvatarWindow(sm, {
      onDoubleClick: () => this.meetingCoordinator.toggleRecording(false),
      onClick: avatar => AvatarChat.toggle(avatar, this.avatar.window, this.meetingCoordinator.momGen, () => this.meetingCoordinator.isRecording),
    });
    this.inputHandler = new InputHandler(sm, () => this.avatar.recordKeystroke(),
      { down: () => this.avatar.globalMouseDown(), up: () => this.avatar.globalMouseUp() });
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
      Automations.fire("day", filePath.replace(/\.[^.\\/]+$/, ".md"));
    };

    // Both land around 9am on a Sunday. Each waits for an answer, and the
    // week (written second) would replace the tasks, so closing the week
    // card brings the tasks back.
    this.dayLogger.onMorningTasks = (tasks, page) => this.showOpenTasks(tasks, page);
    this.dayLogger.onWeekReady = (line, filePath) => {
      Automations.fire("week", filePath.replace(/\.[^.\\/]+$/, ".md"));
      const back = () => this.pendingTasksCard?.();
      ui.ask({ icon: "☀️", title: "Your week, in short", lines: [line], buttons: [
        { title: "Open", action: () => { openFile(filePath); back(); } },
        { title: "Later", action: back },
      ] });
    };

    this.meetingDetector = MeetingDetector.shared;
    this.meetingDetector.onMicAppChanged = app => this.offerToRecordMic(app);
    this.chatbotEngine = ChatbotEngine.shared;
    this.chatbotEngine.onRepliesSent = (batch, drafted) => this.showReplyCard(batch, drafted);
    GoogleSync.onChatTaskBlocked = block => this.showChatTaskBlocked(block);
    this.whatsAppActivityLogger = WhatsAppActivityLogger.shared;

    bus.on("activeTexterChanged", name => ui.setActiveTexter(name));
    bus.on("meetingStateChanged", inMeeting => {
      cblog(`NikxelApp: handleMeetingStateChanged → isInMeeting=${inMeeting}`);
      this.offerToRecord(inMeeting);
    });

    SummaryTemplates.seedIfMissing();
    this.setupDashboard();
    Automations.start(this.meetingCoordinator.momGen);
    this.setupTray();
    this.agentMonitor.startMonitoring();
    this.inputHandler.startMonitoring();
    this.calendarWatcher.start();
    this.reminderWatcher.start();
    this.dayLogger.start();
    PageShare.start();
    ERP.startIfConnected();
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
      this.maybeAskRole();
      // Once, for anyone who set up before the tour existed: the menus moved into the Nikxel window.
      setTimeout(() => CoachTour.startIfNew(this.tourHost), 10_000);
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
    ensureDesktopShortcut();
    // Once Explorer has seen the tray icon (it files it a few seconds after it appears).
    setTimeout(() => void promoteTrayIcon(), 8000);

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

  /// Ask the user's role once. It sets the summary template, so daily, weekly
  /// and meeting summaries are shaped for how they actually work. Mirrors
  /// NikxelApp.maybeAskRole in src/NikxelApp.swift.
  private maybeAskRole(): void {
    if (Settings.roleAsked) return;
    setTimeout(() => {
      void dialog.showMessageBox({
        type: "question", title: "Nikxel", noLink: true,
        message: "What do you do most?",
        detail: "Nikxel shapes your daily and weekly summaries — and your meeting notes — for your role. You can change this any time under Summary Style.",
        buttons: ["I write code", "I run product / projects", "I'm a founder / leader", "Something else"],
        defaultId: 0, cancelId: 3,
      }).then(r => {
        const slugs = ["developer", "project-manager", "co-founder", "default"];
        Settings.summaryTemplate = slugs[r.response] ?? "default";
        Settings.roleAsked = true;
        cblog(`NikxelApp: role set to ${Settings.summaryTemplate}`);
      });
    }, 6000);
  }

  /// What the first-run tour points at.
  private get tourHost(): TourHost {
    return {
      avatarRect: () => this.avatar.avatarRect(),
      showAvatar: () => this.showAvatar(),
      tray: () => this.tray ?? null,
      openDashboard: () => Dashboard.show("home"),
      busy: () => this.meetingDetector.isInMeeting || this.meetingCoordinator.isRecording,
    };
  }

  private showOnboarding(): void {
    if (!this.onboarding) {
      this.onboarding = new OnboardingWindowController(this.meetingCoordinator.momGen);
      this.onboarding.onFinished = () => CoachTour.startIfNew(this.tourHost);
    }
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

  /// Only what's needed in a hurry; every setting lives in the Nikxel window.
  private buildMenu(): Menu {
    const recorder = this.meetingCoordinator.recorder;
    const forced = this.meetingDetector.manualOverride;
    const bot = this.chatbotEngine.isEnabled;
    const template: MenuItemConstructorOptions[] = [
      { label: "Open Nikxel…", click: () => Dashboard.show() },
      { type: "separator" },
      // The tray is the deliberate path, so it isn't blocked while a summary
      // is still being written.
      { label: `Start/Stop Recording (${CAPTURE_MODE_NAMES[Settings.captureMode]})`, click: () => this.meetingCoordinator.toggleRecording(true) },
      { label: recorder.isMicMuted ? "Unmute Mic" : "Mute Mic", type: "checkbox", checked: recorder.isMicMuted,
        click: () => { recorder.isMicMuted = !recorder.isMicMuted; } },
      { label: forced ? "Stop Forcing Meeting Mode" : "Force Meeting Mode (offline)", type: "checkbox", checked: forced, click: () => {
        this.meetingDetector.manualOverride = !this.meetingDetector.manualOverride;
        cblog(`NikxelApp: toggleForceMeeting → manualOverride=${this.meetingDetector.manualOverride}, isInMeeting=${this.meetingDetector.isInMeeting}`);
      } },
      { type: "separator" },
      { label: bot ? "WhatsApp Auto-Replies: On" : "WhatsApp Auto-Replies: Off", type: "checkbox", checked: bot,
        click: () => { this.chatbotEngine.isEnabled = !this.chatbotEngine.isEnabled; } },
      { label: this.avatar.isVisible() ? "Hide Nikxel" : "Show Nikxel", click: () => this.toggleVisibility() },
      { type: "separator" },
      { label: "Quit Nikxel", click: () => app.quit() },
    ];
    return Menu.buildFromTemplate(template);
  }

  /// The Nikxel window (dashboardWindow.ts) reaches the tray's old handlers through this.
  private setupDashboard(): void {
    const actions: Record<string, () => unknown> = {
      summarizeNow: () => this.dayLogger.generateSummaryNow(),
      summarizeWeek: () => this.dayLogger.generateWeekNow(),
      openNotes: () => openFolder(documentsDir("notes")),
      openMeetings: () => openFolder(documentsDir("meetings")),
      openDaily: () => openFolder(documentsDir("daily")),
      openUsage: () => openFolder(UsageLog.directory),
      regenerate: () => this.regenerateUnfinished(),
      aboutMeVoice: () => showAboutMe(),
      openWhatsApp: () => ChromeWhatsApp.activate(),
      whatsappConnection: () => (Settings.whatsappConnected ? this.disconnectWhatsApp() : this.showOnboarding()),
      connectGoogle: () => this.calendarWatcher.reauthenticate(),
      connectSlack: () => this.connectSlack(),
      connectReminders: () => this.reminderWatcher.reauthenticate(),
      connectDashboard: () => this.connectDashboard(),
      connectERP: () => this.connectERP(),
      editSettings: () => this.editSettings(),
      copyLogs: () => this.copyLogs(),
      checkUpdates: () => this.checkForUpdates(),
      setupWizard: () => this.showOnboarding(),
      replayTour: () => CoachTour.replay(this.tourHost),
      toggleRecording: () => this.meetingCoordinator.toggleRecording(true),
      toggleMicMute: () => { this.meetingCoordinator.recorder.isMicMuted = !this.meetingCoordinator.recorder.isMicMuted; },
      toggleVisibility: () => this.toggleVisibility(),
      quit: () => app.quit(),
      newTemplate: () => this.newTemplate(),
      resetTemplate: () => this.resetActiveTemplate(),
      deleteTemplate: () => this.deleteActiveTemplate(),
      openTemplates: () => openFolder(SummaryTemplates.templatesDir),
    };
    Dashboard.init({
      agent: this.meetingCoordinator.momGen,
      isRecording: () => this.meetingCoordinator.isRecording,
      recordingSince: () => (this.meetingCoordinator.recorder.startedAt?.getTime() ?? 0) / 1000,
      isMicMuted: () => this.meetingCoordinator.recorder.isMicMuted,
      isAvatarVisible: () => this.avatar.isVisible(),
      applyAvatarSize: () => this.avatar.applyAvatarSize(),
      action: name => { void actions[name]?.(); },
    });
  }

  private toggleVisibility(): void {
    if (this.avatar.isVisible()) this.avatar.hide();
    else this.showAvatar();
  }

  private async connectERP(): Promise<void> {
    if (ERP.isConnected()) {
      await dialog.showMessageBox({
        type: "info", title: "Nikxel", noLink: true,
        message: "Forklyft ERP is connected",
        detail: "Nikxel reads your team and files tasks through your logged-in ERP session. Use the Assign button on a meeting's action items.",
        buttons: ["OK"],
      });
      return;
    }
    const ok = await ERP.signIn();
    await dialog.showMessageBox({
      type: ok ? "info" : "warning", title: "Nikxel", noLink: true,
      message: ok ? "Forklyft ERP connected" : "ERP not connected",
      detail: ok
        ? "You can now Assign action items to the ERP from any meeting summary. Nikxel also reads and summarizes your ERP into your work context."
        : "Sign-in didn't complete. Open the menu and try “Connect Forklyft ERP…” again.",
      buttons: ["OK"],
    });
    if (ok) void ErpCrawl.ingest((p, k) => this.meetingCoordinator.momGen.runPrompt(p, k));
  }

  /// Disconnecting is for people who don't want WhatsApp in Nikxel at all:
  /// the WhatsApp window stops reopening itself, across restarts too.
  private disconnectWhatsApp(): void {
    ui.ask({
      title: "Disconnect WhatsApp?",
      lines: ["Auto-replies stop, the WhatsApp window closes and won't open again, and Nikxel logs out of WhatsApp.",
        "Reconnect any time from this menu."],
      buttons: [
        { title: "Disconnect", action: () => {
          this.chatbotEngine.isEnabled = false;
          void ChromeWhatsApp.disconnect().then(() =>
            ui.tell({ icon: "💬", title: "WhatsApp disconnected", lines: ["Nikxel won't open WhatsApp again until you reconnect."] }));
        } },
        { title: "Cancel", action: () => {} },
      ],
    });
  }

  /// Signs in to Slack in the browser. The daily summary reads the day's
  /// messages with the token; nothing else does.
  private connectSlack(): void {
    if (!Slack.isConnected()) { void this.startSlackSignIn(); return; }
    ui.ask({
      title: "Slack is connected", lines: ["Today's messages go into your daily summary."],
      buttons: [
        { title: "Reconnect", action: () => void this.startSlackSignIn() },
        { title: "Disconnect", action: () => {
          Slack.disconnect();
          ui.tell({ icon: "💬", title: "Slack disconnected", lines: ["Summaries no longer include Slack."] });
        } },
        { title: "Cancel", action: () => {} },
      ],
    });
  }

  private async startSlackSignIn(): Promise<void> {
    try {
      const team = await Slack.connect();
      ui.tell({ icon: "💬", title: "Slack connected", lines: [`${team}: today's messages go into your daily summary.`] });
    } catch (e) {
      ui.tell({ icon: "⚠️", title: "Slack sign-in didn't finish", kind: "warning", lines: [`Slack said: ${(e as Error).message}.`] });
    }
  }

  /// Set while the open-tasks card is up, to show it again after a card
  /// that replaced it.
  private pendingTasksCard: (() => void) | null = null;

  private showOpenTasks(tasks: string[], page: string): void {
    const shown = tasks.slice(0, 5).map(t => t.length > 110 ? t.slice(0, 109) + "…" : t);
    const more = tasks.length > 5 ? [`…and ${tasks.length - 5} more in the summary.`] : [];
    const show = () => ui.ask({
      icon: "📌", title: tasks.length === 1 ? "1 task still open" : `${tasks.length} tasks still open`,
      lines: [...shown, ...more], bulleted: true, buttons: [
        { title: "Open summary", action: () => { this.pendingTasksCard = null; openFile(page); } },
        { title: "Got it", action: () => { this.pendingTasksCard = null; } },
      ],
    });
    this.pendingTasksCard = show;
    show();
  }

  private async connectDashboard(): Promise<void> {
    const r = await promptText({
      title: "Connect to dashboard",
      message: "Enter the 6-digit pairing code from your org dashboard. Only your work summary (what you worked on and for how long) is shared — never your logs, messages or email.",
      placeholder: "123456",
      buttons: ["Connect", "Cancel"],
    });
    if (r.button !== 0) return;
    const ok = await CloudSync.pair(r.value);
    ui.tell({
      icon: ok ? "✅" : "⚠️", title: ok ? "Connected to dashboard" : "Couldn't connect", kind: ok ? "info" : "warning",
      lines: [ok ? "Your daily work summary will be shared with your org." : "Check the code and that the dashboard is reachable, then try again."],
    });
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
      lines: ["Nikxel will quit, rebuild and come back in a few minutes.", "A window shows how far along it is."], kind: "info", lifetime: 10 });
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
function shortcutTo(lnk: string): boolean {
  return shell.writeShortcutLink(lnk, fs.existsSync(lnk) ? "replace" : "create", {
    target: process.execPath,
    args: `"${app.getAppPath()}"`,
    cwd: app.getAppPath(),
    icon: resourcePath("icon.ico"),
    iconIndex: 0,
    appUserModelId: "com.nikxel.Nikxel",
    description: "Nikxel — your pixel desktop companion",
  });
}

function ensureStartMenuShortcut(): void {
  if (process.platform !== "win32" || app.isPackaged) return;
  const lnk = path.join(app.getPath("appData"), "Microsoft", "Windows", "Start Menu", "Programs", "Nikxel.lnk");
  if (!shortcutTo(lnk)) cblog("NikxelApp: couldn't write the Start menu shortcut");
}

/// "Nikxel" on the desktop, made at first launch for people who look there
/// first. Kept pointing at this copy while it exists; once deleted, not made again.
function ensureDesktopShortcut(): void {
  if (process.platform !== "win32" || app.isPackaged) return;
  const lnk = path.join(app.getPath("desktop"), "Nikxel.lnk");
  if (Settings.desktopShortcutMade && !fs.existsSync(lnk)) return;
  if (shortcutTo(lnk)) Settings.desktopShortcutMade = true;
  else cblog("NikxelApp: couldn't write the desktop shortcut");
}

/// Windows tucks a new tray icon under the ^ by the clock, where nobody finds
/// it. Windows 11 keeps a per-icon "show on the taskbar" switch in the user's
/// own registry (NotifyIconSettings\…\IsPromoted, what Settings → Taskbar →
/// Other system tray icons flips); turn Nikxel's on, once. No such key on
/// Windows 10, where the tour walks the user through pinning it instead.
/// Apps can't pin themselves to the taskbar itself: Windows doesn't allow it.
async function promoteTrayIcon(tries = 3): Promise<void> {
  if (process.platform !== "win32" || Settings.trayPromoted) return;
  const exe = process.execPath.replace(/'/g, "''");
  const r = await powershell(`
$hit = $false
foreach ($k in Get-ChildItem 'HKCU:\\Control Panel\\NotifyIconSettings' -ErrorAction SilentlyContinue) {
  $p = Get-ItemProperty $k.PSPath
  if ($p.ExecutablePath -and $p.ExecutablePath -ieq '${exe}') { Set-ItemProperty $k.PSPath -Name IsPromoted -Value 1 -Type DWord; $hit = $true }
}
if ($hit) { 'promoted' } elseif (Test-Path 'HKCU:\\Control Panel\\NotifyIconSettings') { 'not yet' } else { 'no key' }`, { timeoutMs: 15_000 }).catch(() => null);
  const out = (r?.stdout ?? "").trim();
  cblog(`NikxelApp: tray icon on the taskbar → ${out || "failed"}`);
  if (out === "promoted" || out === "no key") Settings.trayPromoted = true;
  else if (tries > 1) setTimeout(() => void promoteTrayIcon(tries - 1), 60_000);
}

