import Cocoa
import UserNotifications

class NikxelAppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    var window: NikxelWindow!
    var statusItem: NSStatusItem!
    var agentMonitor: AgentMonitor!
    var inputHandler: InputHandler!
    var stateMachine: StateMachine!
    var calendarWatcher: GoogleCalendarWatcher!
    var reminderWatcher: ReminderWatcher!
    var meetingCoordinator: MeetingCoordinator!
    var dayLogger: DayLogger!
    var meetingDetector: MeetingDetector!
    var chatbotEngine: ChatbotEngine!
    var whatsAppActivityLogger: WhatsAppActivityLogger!
    var onboardingWindowController: OnboardingWindowController?
    private var reminderDismissTimer: Timer?
    private var muteMenuItem: NSMenuItem?
    private var noteFormatItems: [NSMenuItem] = []
    private var recordMenuItem: NSMenuItem?
    private var modeNotesItem: NSMenuItem?
    private var modeMeetingItem: NSMenuItem?
    private var forceMeetingItem: NSMenuItem?
    private var botMenuItem: NSMenuItem?
    private var waModeItems: [NSMenuItem] = []
    private var waGroupItem: NSMenuItem?
    private var waContextItem: NSMenuItem?
    private var waDraftItem: NSMenuItem?
    private var waQuietItem: NSMenuItem?
    private var waChatTasksItem: NSMenuItem?
    private var googleSyncMenuItem: NSMenuItem?
    private var templateMenu: NSMenu?

    func applicationDidFinishLaunching(_ notification: Notification) {
        stateMachine = StateMachine()
        agentMonitor = AgentMonitor(stateMachine: stateMachine)
        inputHandler = InputHandler(stateMachine: stateMachine)

        window = NikxelWindow(stateMachine: stateMachine)
        inputHandler.nikxelView = window.nikxelView
        // Trigger the puff BEFORE the window orders in so the very first frame
        // the user sees already has the avatar hidden + dust forming. Any
        // visible-Nikxel-before-cloud flash would otherwise be a draw cycle
        // with avatarHiddenByPuff still false.
        window.nikxelView?.triggerPuff()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        meetingCoordinator = MeetingCoordinator(stateMachine: stateMachine)
        meetingCoordinator.nikxelView = window.nikxelView
        window.onDoubleClick = { [weak self] in self?.meetingCoordinator.toggleRecording(force: false) }

        calendarWatcher = GoogleCalendarWatcher(stateMachine: stateMachine)
        calendarWatcher.onReminder = { [weak self] text in self?.showReminder(text: text) }

        reminderWatcher = ReminderWatcher()
        reminderWatcher.onReminder = { [weak self] reminder in
            self?.window.nikxelView?.pushReminder(id: reminder.id, title: reminder.title)
        }
        window.nikxelView?.onReminderTapped = { [weak self] id in
            self?.reminderWatcher.complete(id: id)
        }

        UNUserNotificationCenter.current().delegate = self

        dayLogger = DayLogger(momGenerator: meetingCoordinator.momGen)
        dayLogger.onSummaryReady = { [weak self] line, fileURL in
            // Ten minutes: this fires at 10pm, so it has to survive the user
            // being away from the Mac when it lands.
            self?.window.nikxelView?.showCard(
                icon: "🌙", title: "Today, in short", lines: [line],
                kind: .info, lifetime: 600,
                action: { NSWorkspace.shared.open(fileURL) })
        }

        meetingDetector = MeetingDetector.shared
        chatbotEngine = ChatbotEngine.shared
        chatbotEngine.onRepliesSent = { [weak self] batch, drafted in
            self?.showReplyCard(batch, drafted: drafted)
        }
        GoogleSync.onChatTaskBlocked = { [weak self] block in
            guard let self = self else { return }
            switch block {
            case .needsReconnect:
                self.window.nikxelView?.showCard(
                    icon: "🔑", title: "Reconnect Google to file tasks",
                    lines: ["Your account was connected before Nikxel could write to Tasks.",
                            "Tap to reconnect — one click, nothing else changes."],
                    kind: .warning, lifetime: .infinity,
                    action: { [weak self] in self?.calendarWatcher.reauthenticate() })
            case .apiDisabled(let url):
                self.window.nikxelView?.showCard(
                    icon: "🔧", title: "Turn on the Google Tasks API",
                    lines: ["Your Google project hasn't enabled Tasks, so nothing can be filed.",
                            url == nil ? "Enable it in the Google Cloud console."
                                       : "Tap to open the page that switches it on."],
                    kind: .warning, lifetime: .infinity,
                    action: url.flatMap(URL.init(string:)).map { u in { NSWorkspace.shared.open(u) } })
            case .other(let reason):
                self.window.nikxelView?.showCard(
                    icon: "⚠️", title: "Couldn't file a task from a chat",
                    lines: [String(reason.prefix(160))],
                    kind: .warning, lifetime: 30)
            }
        }
        whatsAppActivityLogger = WhatsAppActivityLogger.shared

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleActiveTexterChanged(_:)),
            name: .activeTexterChanged,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleMeetingStateChanged),
            name: .meetingStateChanged,
            object: nil
        )

        SummaryTemplates.seedIfMissing()
        setupMenuBar()
        agentMonitor.startMonitoring()
        inputHandler.startMonitoring()
        calendarWatcher.start()
        reminderWatcher.start()
        dayLogger.start()
        meetingDetector.start()
        chatbotEngine.start(with: meetingCoordinator.momGen)
        whatsAppActivityLogger.start()
        cblog("NikxelApp: didFinishLaunching — detectors started")

        // Self-heal: macOS Timers don't fire while the Mac is asleep, so the
        // 22:00 scheduled summary can silently miss if the lid was closed.
        // On wake, re-check and backfill if today's file is still missing.
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
        // Trigger TCC prompt on launch so it's granted before user hits record
        meetingCoordinator.recorder.warmUpPermission()

        if !NikxelSettings.onboardingCompleted {
            showOnboarding()
        }

        // A summary interrupted by a quit or crash leaves its marker behind.
        let unfinished = meetingCoordinator.momGen.unfinishedJobs()
        if !unfinished.isEmpty {
            window.nikxelView?.pushReminder(
                id: "nikxel.unfinished",
                title: "\(unfinished.count) summary\(unfinished.count == 1 ? "" : "s") unfinished — see the menu bar"
            )
        }
    }

    func showOnboarding() {
        if onboardingWindowController == nil {
            onboardingWindowController = OnboardingWindowController(momGenerator: meetingCoordinator.momGen)
        }
        onboardingWindowController?.show()
    }

    func applicationWillTerminate(_ notification: Notification) {
        agentMonitor.stopMonitoring()
        inputHandler.stopMonitoring()
        calendarWatcher.stop()
        reminderWatcher.stop()
        dayLogger.stop()
        meetingDetector.stop()
        chatbotEngine.stop()
        whatsAppActivityLogger.stop()
    }

    func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let btn = statusItem.button { btn.title = "🐱" }
        let menu = NSMenu()
        let toggle = NSMenuItem(title: "Show/Hide Nikxel", action: #selector(toggleVisibility), keyEquivalent: "")
        toggle.target = self; menu.addItem(toggle)

        let record = NSMenuItem(title: "Start/Stop Recording", action: #selector(toggleRecording), keyEquivalent: "r")
        record.target = self; menu.addItem(record)
        self.recordMenuItem = record

        let forceMeet = NSMenuItem(title: "Force Meeting Mode (offline)", action: #selector(toggleForceMeeting), keyEquivalent: "")
        forceMeet.target = self; menu.addItem(forceMeet)
        self.forceMeetingItem = forceMeet
        refreshForceMeetingItem()

        let mute = NSMenuItem(title: "Mute Mic", action: #selector(toggleMicMute), keyEquivalent: "m")
        mute.target = self; menu.addItem(mute)
        self.muteMenuItem = mute
        refreshMuteMenuItem()

        let waItem = NSMenuItem(title: "WhatsApp Bot", action: nil, keyEquivalent: "")
        let waMenu = NSMenu()

        let bot = NSMenuItem(title: "Auto-Replies: On",
                             action: #selector(toggleBotEnabled), keyEquivalent: "")
        bot.target = self; waMenu.addItem(bot)
        self.botMenuItem = bot

        waMenu.addItem(NSMenuItem.separator())
        waMenu.addItem(sectionHeader("Reply…"))
        for mode in WABotMode.allCases {
            let item = NSMenuItem(title: mode.displayName, action: #selector(setWABotMode(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode.rawValue
            waMenu.addItem(item)
            waModeItems.append(item)
        }

        waMenu.addItem(NSMenuItem.separator())
        let groups = NSMenuItem(title: "Group Chats: Off",
                                action: #selector(toggleWAGroups), keyEquivalent: "")
        groups.target = self; waMenu.addItem(groups)
        self.waGroupItem = groups

        let draft = NSMenuItem(title: "Draft Only (don't send): Off",
                               action: #selector(toggleWADraftOnly), keyEquivalent: "")
        draft.target = self; waMenu.addItem(draft)
        self.waDraftItem = draft

        let quiet = NSMenuItem(title: "Quiet Hours: Off",
                               action: #selector(toggleWAQuietHours), keyEquivalent: "")
        quiet.target = self; waMenu.addItem(quiet)
        self.waQuietItem = quiet

        let ctx = NSMenuItem(title: "Knows What You're Working On: On",
                             action: #selector(toggleWAWorkContext), keyEquivalent: "")
        ctx.target = self; waMenu.addItem(ctx)
        self.waContextItem = ctx

        let chatTasks = NSMenuItem(title: "Tasks from Chats: On",
                                   action: #selector(toggleWAChatTasks), keyEquivalent: "")
        chatTasks.target = self; waMenu.addItem(chatTasks)
        self.waChatTasksItem = chatTasks

        waMenu.addItem(NSMenuItem.separator())
        let editPersonalityWA = NSMenuItem(title: "Edit Bot Personality…", action: #selector(editBotPersonality), keyEquivalent: "")
        editPersonalityWA.target = self; waMenu.addItem(editPersonalityWA)

        let editTrusted = NSMenuItem(title: "Edit Trusted Contacts…", action: #selector(editTrustedContacts), keyEquivalent: "")
        editTrusted.target = self; waMenu.addItem(editTrusted)

        let editNever = NSMenuItem(title: "Edit Never-Reply List…", action: #selector(editNeverReply), keyEquivalent: "")
        editNever.target = self; waMenu.addItem(editNever)

        waItem.submenu = waMenu
        menu.addItem(waItem)
        refreshWAMenu()

        let modeItem = NSMenuItem(title: "Capture Mode", action: nil, keyEquivalent: "")
        let modeSubmenu = NSMenu()
        let notesMode = NSMenuItem(title: "Notes (videos, lectures, podcasts)", action: #selector(setModeNotes), keyEquivalent: "")
        notesMode.target = self; modeSubmenu.addItem(notesMode)
        self.modeNotesItem = notesMode
        let meetingMode = NSMenuItem(title: "Meeting (per-speaker)", action: #selector(setModeMeeting), keyEquivalent: "")
        meetingMode.target = self; modeSubmenu.addItem(meetingMode)
        self.modeMeetingItem = meetingMode
        modeItem.submenu = modeSubmenu
        menu.addItem(modeItem)
        refreshModeMenuItems()

        let formatItem = NSMenuItem(title: "Note Format", action: nil, keyEquivalent: "")
        let formatSubmenu = NSMenu()
        for format in NoteExporter.Format.allCases {
            let item = NSMenuItem(title: format.displayName, action: #selector(setNoteFormat(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = format.rawValue
            formatSubmenu.addItem(item)
            noteFormatItems.append(item)
        }
        formatItem.submenu = formatSubmenu
        menu.addItem(formatItem)
        refreshNoteFormatMenuItems()

        let openNotes = NSMenuItem(title: "Open Notes Folder", action: #selector(openNotes), keyEquivalent: "")
        openNotes.target = self; menu.addItem(openNotes)

        let openMoms = NSMenuItem(title: "Open Meetings Folder", action: #selector(openMeetings), keyEquivalent: "")
        openMoms.target = self; menu.addItem(openMoms)

        let openDaily = NSMenuItem(title: "Open Daily Summaries Folder", action: #selector(openDaily), keyEquivalent: "")
        openDaily.target = self; menu.addItem(openDaily)

        let summarizeNow = NSMenuItem(title: "Summarize Today Now", action: #selector(summarizeNow), keyEquivalent: "")
        summarizeNow.target = self; menu.addItem(summarizeNow)

        let connectGCal = NSMenuItem(title: "Connect Google Account…", action: #selector(connectGoogleCalendar), keyEquivalent: "")
        connectGCal.target = self; menu.addItem(connectGCal)

        let gsync = NSMenuItem(title: "Send Meeting Tasks to Google: On",
                               action: #selector(toggleGoogleSync), keyEquivalent: "")
        gsync.target = self; menu.addItem(gsync)
        googleSyncMenuItem = gsync
        refreshGoogleSyncMenuTitle()

        let connectReminders = NSMenuItem(title: "Connect Apple Reminders…", action: #selector(connectAppleReminders), keyEquivalent: "")
        connectReminders.target = self; menu.addItem(connectReminders)

        let templateItem = NSMenuItem(title: "Summary Template", action: nil, keyEquivalent: "")
        let templateSubmenu = NSMenu()
        templateItem.submenu = templateSubmenu
        templateMenu = templateSubmenu
        rebuildTemplateMenu()
        menu.addItem(templateItem)

        let editSettings = NSMenuItem(title: "Edit Nikxel Settings (name, language)…", action: #selector(editSettings), keyEquivalent: "")
        editSettings.target = self; menu.addItem(editSettings)

        let regenerate = NSMenuItem(title: "Regenerate Unfinished Summary…", action: #selector(regenerateUnfinished), keyEquivalent: "")
        regenerate.target = self; menu.addItem(regenerate)

        let setupWizard = NSMenuItem(title: "Setup Wizard…", action: #selector(openOnboarding), keyEquivalent: "")
        setupWizard.target = self; menu.addItem(setupWizard)

        menu.addItem(NSMenuItem.separator())
        let quit = NSMenuItem(title: "Quit Nikxel", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self; menu.addItem(quit)
        statusItem.menu = menu
    }

    @objc func toggleVisibility() {
        if window.isVisible {
            window.orderOut(nil)
        } else {
            // Hide the avatar + start the dust BEFORE the window orders in so
            // the first frame on screen is already mid-puff (not a Nikxel flash).
            window.nikxelView?.triggerPuff()
            window.makeKeyAndOrderFront(nil)
        }
    }

    @objc func toggleRecording() {
        // Menu bar is the deliberate path, so it isn't blocked while a summary
        // is still being written.
        meetingCoordinator.toggleRecording(force: true)
    }

    @objc func toggleForceMeeting() {
        meetingDetector.manualOverride.toggle()
        cblog("NikxelApp: toggleForceMeeting → manualOverride=\(meetingDetector.manualOverride), isInMeeting=\(MeetingDetector.shared.isInMeeting)")
        refreshForceMeetingItem()
    }

    private func refreshForceMeetingItem() {
        let on = meetingDetector?.manualOverride ?? false
        forceMeetingItem?.state = on ? .on : .off
        forceMeetingItem?.title = on ? "Stop Forcing Meeting Mode" : "Force Meeting Mode (offline)"
    }

    @objc func toggleMicMute() {
        meetingCoordinator.recorder.isMicMuted.toggle()
        refreshMuteMenuItem()
    }

    private func refreshMuteMenuItem() {
        let muted = meetingCoordinator?.recorder.isMicMuted ?? false
        muteMenuItem?.title = muted ? "Unmute Mic" : "Mute Mic"
        muteMenuItem?.state = muted ? .on : .off
    }

    @objc func toggleBotEnabled() {
        ChatbotEngine.shared.isEnabled.toggle()
        refreshWAMenu()
    }

    @objc func setWABotMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let mode = WABotMode(rawValue: raw) else { return }
        NikxelSettings.waBotMode = mode
        ChatbotEngine.shared.applyModeChange()
        refreshWAMenu()
    }

    @objc func toggleWAGroups() {
        NikxelSettings.waGroupReplies.toggle()
        refreshWAMenu()
    }

    @objc func toggleWAWorkContext() {
        NikxelSettings.waWorkContext.toggle()
        refreshWAMenu()
    }

    @objc func toggleWADraftOnly() {
        NikxelSettings.waDraftOnly.toggle()
        refreshWAMenu()
    }

    @objc func toggleWAQuietHours() {
        NikxelSettings.waQuietHours.toggle()
        refreshWAMenu()
    }

    @objc func toggleWAChatTasks() {
        NikxelSettings.waChatTasks.toggle()
        refreshWAMenu()
    }

    @objc func editTrustedContacts() {
        NSWorkspace.shared.open(WAContactLists.seedIfMissing(.trusted))
    }

    @objc func editNeverReply() {
        NSWorkspace.shared.open(WAContactLists.seedIfMissing(.neverReply))
    }

    /// "22" -> "10pm". Menu titles read better than 24h clock time here.
    private static func hourLabel(_ h: Int) -> String {
        let suffix = h < 12 ? "am" : "pm"
        let twelve = h % 12 == 0 ? 12 : h % 12
        return "\(twelve)\(suffix)"
    }

    private func refreshWAMenu() {
        let on = ChatbotEngine.shared.isEnabled
        botMenuItem?.state = on ? .on : .off
        botMenuItem?.title = on ? "Auto-Replies: On" : "Auto-Replies: Off"

        let mode = NikxelSettings.waBotMode
        for item in waModeItems {
            let isCurrent = (item.representedObject as? String) == mode.rawValue
            item.state = isCurrent ? .on : .off
        }
        // Only the unattended mode has a delay to name, and it's edited in
        // settings.json rather than here -- a submenu of minute choices for a
        // number nobody changes twice isn't worth the clicks.
        if let item = waModeItems.first(where: { ($0.representedObject as? String) == WABotMode.unattended.rawValue }) {
            item.title = "Any time, if unanswered for \(NikxelSettings.waUnattendedMinutes) min"
        }

        let groups = NikxelSettings.waGroupReplies
        waGroupItem?.state = groups ? .on : .off
        waGroupItem?.title = groups ? "Group Chats: Only When Tagged" : "Group Chats: Off"

        let ctx = NikxelSettings.waWorkContext
        waContextItem?.state = ctx ? .on : .off
        waContextItem?.title = ctx ? "Knows What You're Working On: On"
                                  : "Knows What You're Working On: Off"

        let draft = NikxelSettings.waDraftOnly
        waDraftItem?.state = draft ? .on : .off
        waDraftItem?.title = draft ? "Draft Only (don't send): On"
                                   : "Draft Only (don't send): Off"

        let quiet = NikxelSettings.waQuietHours
        waQuietItem?.state = quiet ? .on : .off
        waQuietItem?.title = quiet
            ? "Quiet Hours: \(Self.hourLabel(NikxelSettings.waQuietFrom))–\(Self.hourLabel(NikxelSettings.waQuietTo))"
            : "Quiet Hours: Off"

        let chatTasks = NikxelSettings.waChatTasks
        waChatTasksItem?.state = chatTasks ? .on : .off
        waChatTasksItem?.title = chatTasks ? "Tasks from Chats: On" : "Tasks from Chats: Off"
    }

    /// A disabled item used as a label inside a submenu.
    private func sectionHeader(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    @objc func setModeNotes() {
        CaptureMode.current = .notes
        refreshModeMenuItems()
    }

    @objc func setModeMeeting() {
        CaptureMode.current = .meeting
        refreshModeMenuItems()
    }

    private func refreshModeMenuItems() {
        let mode = CaptureMode.current
        modeNotesItem?.state = mode == .notes ? .on : .off
        modeMeetingItem?.state = mode == .meeting ? .on : .off
        recordMenuItem?.title = "Start/Stop Recording (\(mode.displayName))"
    }

    @objc func openNotes() {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/nikxel/notes", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(dir)
    }

    @objc func openMeetings() {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/nikxel/meetings", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(dir)
    }

    @objc func openDaily() {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/nikxel/daily", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(dir)
    }

    @objc func handleWake() {
        // Fire on the next runloop tick so any other wake handlers settle first.
        DispatchQueue.main.async { [weak self] in self?.dayLogger.backfillIfMissed() }
    }

    @objc func handleActiveTexterChanged(_ notification: Notification) {
        let name = notification.userInfo?["name"] as? String
        window.nikxelView?.activeTexterName = name
    }

    @objc func handleMeetingStateChanged() {
        let state = MeetingDetector.shared.isInMeeting
        cblog("NikxelApp: handleMeetingStateChanged → isInMeeting=\(state)")
        window.nikxelView?.isInMeeting = state
    }

    @objc func summarizeNow() {
        dayLogger.generateSummaryNow()
    }

    @objc func setNoteFormat(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let format = NoteExporter.Format(rawValue: raw) else { return }
        NikxelSettings.noteFormat = format
        refreshNoteFormatMenuItems()
    }

    private func refreshNoteFormatMenuItems() {
        let current = NikxelSettings.noteFormat
        for item in noteFormatItems {
            item.state = (item.representedObject as? String) == current.rawValue ? .on : .off
        }
    }

    /// Offers to re-run the newest summary that was started but never written,
    /// from the transcript saved before generation. This is the recovery path
    /// for a quit, crash, or agent failure mid-generation.
    @objc func regenerateUnfinished() {
        let jobs = meetingCoordinator.momGen.unfinishedJobs()
        guard let job = jobs.first else {
            let alert = NSAlert()
            alert.messageText = "Nothing to regenerate"
            alert.informativeText = "Every recording you've made has a summary."
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }

        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        let alert = NSAlert()
        alert.messageText = "Regenerate this summary?"
        alert.informativeText = """
        \(job.mode == .notes ? "Notes" : "Meeting") from \(formatter.string(from: job.startedAt)).
        The transcript is saved — this re-runs your coding agent over it.
        \(jobs.count > 1 ? "\n\(jobs.count - 1) more unfinished after this one." : "")
        """
        alert.addButton(withTitle: "Regenerate")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        stateMachine.startWritingMOM()
        meetingCoordinator.momGen.regenerate(job) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.stateMachine.endWritingMOM()
                switch result {
                case .success(let url):
                    self.stateMachine.triggerMomReady()
                    NSWorkspace.shared.open(url)
                    if job.mode == .meeting { GoogleSync.offer(noteURL: url) }
                case .failure(let error):
                    let fail = NSAlert()
                    fail.messageText = "Regeneration Failed"
                    fail.informativeText = "\(error)"
                    fail.alertStyle = .critical
                    fail.addButton(withTitle: "OK")
                    fail.runModal()
                }
            }
        }
    }

    @objc func openOnboarding() {
        showOnboarding()
    }

    @objc func connectGoogleCalendar() {
        calendarWatcher.reauthenticate()
    }

    @objc func toggleGoogleSync() {
        NikxelSettings.googleSyncEnabled.toggle()
        refreshGoogleSyncMenuTitle()
    }

    private func refreshGoogleSyncMenuTitle() {
        googleSyncMenuItem?.title = "Send Meeting Tasks to Google: \(NikxelSettings.googleSyncEnabled ? "On" : "Off")"
    }

    // MARK: - Summary templates

    /// Rebuilt rather than mutated, because creating or deleting a template
    /// changes the list itself, not just which row is ticked.
    private func rebuildTemplateMenu() {
        guard let menu = templateMenu else { return }
        menu.removeAllItems()
        let active = NikxelSettings.summaryTemplate

        for t in SummaryTemplates.available() {
            let item = NSMenuItem(title: t.name, action: #selector(selectTemplate(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = t.slug
            item.state = t.slug == active ? .on : .off
            menu.addItem(item)
        }

        menu.addItem(NSMenuItem.separator())
        let activeName = SummaryTemplates.displayName(for: active)

        let edit = NSMenuItem(title: "Edit \u{201C}\(activeName)\u{201D}…", action: #selector(editActiveTemplate), keyEquivalent: "")
        edit.target = self; menu.addItem(edit)

        let newItem = NSMenuItem(title: "New Template…", action: #selector(newTemplate), keyEquivalent: "")
        newItem.target = self; menu.addItem(newItem)

        if SummaryTemplates.isShipped(active) {
            let reset = NSMenuItem(title: "Reset \u{201C}\(activeName)\u{201D} to Default…", action: #selector(resetActiveTemplate), keyEquivalent: "")
            reset.target = self; menu.addItem(reset)
        } else {
            let del = NSMenuItem(title: "Delete \u{201C}\(activeName)\u{201D}…", action: #selector(deleteActiveTemplate), keyEquivalent: "")
            del.target = self; menu.addItem(del)
        }

        let folder = NSMenuItem(title: "Open Templates Folder", action: #selector(openTemplatesFolder), keyEquivalent: "")
        folder.target = self; menu.addItem(folder)
    }

    @objc func selectTemplate(_ sender: NSMenuItem) {
        guard let slug = sender.representedObject as? String else { return }
        NikxelSettings.summaryTemplate = slug
        rebuildTemplateMenu()
    }

    @objc func editActiveTemplate() {
        let slug = NikxelSettings.summaryTemplate
        let alert = NSAlert()
        alert.messageText = "Editing \u{201C}\(SummaryTemplates.displayName(for: slug))\u{201D}"
        alert.informativeText = """
        Write plain instructions, one per line — the same way you'd tell a person. They're added to the prompt your coding agent runs and override the built-in structure: drop a section you don't use, add one you do, change the order, set the length or the tone.

        Lines starting with # are ignored, so the notes already in the file are safe to leave there.

        Takes effect on your next recording. Nikxel still won't invent content to satisfy an instruction — attendees, decisions, owners, numbers and dates come only from the transcript.
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Open \(slug).txt")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        NSWorkspace.shared.open(SummaryTemplates.activeURL)
    }

    @objc func newTemplate() {
        let active = NikxelSettings.summaryTemplate
        let alert = NSAlert()
        alert.messageText = "New summary template"
        alert.informativeText = "Name it after the kind of meeting or the role it's for — \"Client Calls\", \"Design Review\", \"Board\"."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = "Template name"
        alert.accessoryView = field
        alert.addButton(withTitle: "Create, starting blank")
        alert.addButton(withTitle: "Create, copying \u{201C}\(SummaryTemplates.displayName(for: active))\u{201D}")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn || response == .alertSecondButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let copyFrom = response == .alertSecondButtonReturn ? active : nil

        guard let slug = SummaryTemplates.create(named: name, copying: copyFrom) else {
            let fail = NSAlert()
            fail.messageText = "Couldn't create that template"
            fail.informativeText = SummaryTemplates.slugify(name).isEmpty
                ? "Give it a name with at least one letter or number in it."
                : "A template with that name already exists. Pick a different name, or edit the existing one."
            fail.addButton(withTitle: "OK")
            fail.runModal()
            return
        }
        NikxelSettings.summaryTemplate = slug
        rebuildTemplateMenu()
        NSWorkspace.shared.open(SummaryTemplates.url(for: slug))
    }

    @objc func resetActiveTemplate() {
        let slug = NikxelSettings.summaryTemplate
        let name = SummaryTemplates.displayName(for: slug)
        let alert = NSAlert()
        alert.messageText = "Reset \u{201C}\(name)\u{201D} to the built-in version?"
        alert.informativeText = "Anything you've written in \(slug).txt will be replaced. Your other templates aren't touched."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Reset")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        SummaryTemplates.reset(slug)
    }

    @objc func deleteActiveTemplate() {
        let slug = NikxelSettings.summaryTemplate
        let name = SummaryTemplates.displayName(for: slug)
        let alert = NSAlert()
        alert.messageText = "Delete \u{201C}\(name)\u{201D}?"
        alert.informativeText = "\(slug).txt is removed and summaries go back to the Default template."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        SummaryTemplates.delete(slug)
        rebuildTemplateMenu()
    }

    @objc func openTemplatesFolder() {
        NSWorkspace.shared.open(SummaryTemplates.templatesDir)
    }

    @objc func connectAppleReminders() {
        reminderWatcher.reauthenticate()
    }

    @objc func editBotPersonality() {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".nikxel", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("bot_personality.txt")
        // Seed default if missing so the editor opens with something useful.
        if !FileManager.default.fileExists(atPath: url.path) {
            let name = NikxelSettings.userName
            let def = """
            You are \(name)'s friendly AI assistant. You're responding to WhatsApp messages while \(name) is in a meeting. Be casual, warm, and helpful. Keep responses concise (1-3 sentences). Be honest -- say you're \(name)'s assistant, don't pretend to be them.
            """
            try? def.write(to: url, atomically: true, encoding: .utf8)
        }
        NSWorkspace.shared.open(url)
    }

    @objc func editSettings() {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".nikxel", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("settings.json")
        if !FileManager.default.fileExists(atPath: url.path) {
            let def = """
            {
              "userName": "\(NikxelSettings.userName)",
              "waOwnName": "\(NikxelSettings.waOwnName)",
              "language": "auto",
              "botMemoryDays": \(NikxelSettings.botMemoryDays),
              "waUnattendedMinutes": \(NikxelSettings.waUnattendedMinutes),
              "googleSyncEnabled": \(NikxelSettings.googleSyncEnabled)
            }
            """
            try? def.write(to: url, atomically: true, encoding: .utf8)
        }
        let alert = NSAlert()
        alert.messageText = "Nikxel Settings"
        alert.informativeText = """
        userName — your real name, used so meeting MOMs correctly identify "Me" as you (not whoever else gets mentioned on the call).
        waOwnName — your name exactly as it shows in your own WhatsApp account (often your full name) — used to filter your own messages out of chat scraping. Leave as-is if unsure.
        language — "auto" to match whichever language the content is in (English, Hindi, Hinglish, etc.), or a specific language name (e.g. "Hindi") to always force it.
        botMemoryDays — how many days of your end-of-day summaries the WhatsApp bot reads before replying, so it recognises what someone is asking about. It is told never to disclose from them. 0 turns it off; 3 is the default.
        summaryTemplate — which template in ~/.nikxel/templates/ shapes your summaries (developer, hr, project-manager, co-founder, default, or one you made). Pick it from the Summary Template menu instead of editing this by hand.
        waUnattendedMinutes — in "Any time, if unanswered" mode, how many minutes a message must sit unread before the bot answers it. 5 is the default.
        waQuietFrom / waQuietTo — the hours (0-23) quiet hours run between; 22 and 8 by default. Turn them on or off from the WhatsApp Bot menu.
        projectsRoot — the folder scanned for git repos, so day summaries and the WhatsApp bot know what you have been building. Defaults to ~/Desktop; point it at your actual projects folder and the scan is both faster and more accurate.
        googleSyncEnabled — whether a finished meeting summary offers to add its Action Items to Google Tasks and its follow-ups to your calendar. Nothing is ever added without you confirming the list first.
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Open settings.json")
        alert.runModal()
        NSWorkspace.shared.open(url)
    }

    @objc func quitApp() { NSApp.terminate(nil) }

    /// Bubble after the bot has been round a batch of chats. Drafts get a
    /// sterner card than sent replies: a draft is unfinished business sitting in
    /// a chat window, so it stays until clicked and clicking opens the browser.
    private func showReplyCard(_ batch: [ChatbotEngine.Delivered], drafted: Bool) {
        guard !batch.isEmpty else { return }
        var lines = batch.prefix(3).map { d -> String in
            let snippet = d.text.replacingOccurrences(of: "\n", with: " ")
            // 45 keeps a bullet to two rendered lines at the card's width; at
            // 60 a three-contact batch grew taller than the avatar.
            return "\(d.contact) — \(snippet.prefix(45))\(snippet.count > 45 ? "…" : "")"
        }
        if batch.count > 3 { lines.append("…and \(batch.count - 3) more") }
        let tasks = batch.compactMap(\.task)
        if !tasks.isEmpty {
            lines.append("Added \(tasks.count) task\(tasks.count == 1 ? "" : "s") to Google Tasks")
        }

        window.nikxelView?.showCard(
            icon: drafted ? "✍️" : "💬",
            title: drafted
                ? "\(batch.count) draft\(batch.count == 1 ? "" : "s") waiting"
                : "Replied for you",
            lines: lines,
            bulleted: true,
            kind: drafted ? .warning : .success,
            lifetime: drafted ? .infinity : 25,
            action: drafted ? { ChromeWhatsApp.activate() } : nil)
    }

    private func showReminder(text: String) {
        window.nikxelView?.reminderText = text
        reminderDismissTimer?.invalidate()
        reminderDismissTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: false) { [weak self] _ in
            self?.window.nikxelView?.reminderText = nil
        }
    }

    // UNUserNotificationCenterDelegate

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        if let path = response.notification.request.content.userInfo["openPath"] as? String {
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
        }
        completionHandler()
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}

@main
struct NikxelMain {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let delegate = NikxelAppDelegate()
        app.delegate = delegate
        _ = delegate
        app.run()
    }
}
