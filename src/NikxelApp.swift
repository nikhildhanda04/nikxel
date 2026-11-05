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
    private var recordMenuItem: NSMenuItem?
    private var modeNotesItem: NSMenuItem?
    private var modeMeetingItem: NSMenuItem?
    private var forceMeetingItem: NSMenuItem?
    private var botMenuItem: NSMenuItem?

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
        window.onDoubleClick = { [weak self] in self?.meetingCoordinator.toggleRecording() }

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

        meetingDetector = MeetingDetector.shared
        chatbotEngine = ChatbotEngine.shared
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

        let bot = NSMenuItem(title: "WhatsApp Auto-Replies: On",
                             action: #selector(toggleBotEnabled), keyEquivalent: "")
        bot.target = self; menu.addItem(bot)
        self.botMenuItem = bot
        refreshBotMenuItem()

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

        let openNotes = NSMenuItem(title: "Open Notes Folder", action: #selector(openNotes), keyEquivalent: "")
        openNotes.target = self; menu.addItem(openNotes)

        let openMoms = NSMenuItem(title: "Open Meetings Folder", action: #selector(openMeetings), keyEquivalent: "")
        openMoms.target = self; menu.addItem(openMoms)

        let openDaily = NSMenuItem(title: "Open Daily Summaries Folder", action: #selector(openDaily), keyEquivalent: "")
        openDaily.target = self; menu.addItem(openDaily)

        let summarizeNow = NSMenuItem(title: "Summarize Today Now", action: #selector(summarizeNow), keyEquivalent: "")
        summarizeNow.target = self; menu.addItem(summarizeNow)

        let connectGCal = NSMenuItem(title: "Connect Google Calendar…", action: #selector(connectGoogleCalendar), keyEquivalent: "")
        connectGCal.target = self; menu.addItem(connectGCal)

        let connectReminders = NSMenuItem(title: "Connect Apple Reminders…", action: #selector(connectAppleReminders), keyEquivalent: "")
        connectReminders.target = self; menu.addItem(connectReminders)

        let editPersonality = NSMenuItem(title: "Edit Bot Personality…", action: #selector(editBotPersonality), keyEquivalent: "")
        editPersonality.target = self; menu.addItem(editPersonality)

        let editSettings = NSMenuItem(title: "Edit Nikxel Settings (name, language)…", action: #selector(editSettings), keyEquivalent: "")
        editSettings.target = self; menu.addItem(editSettings)

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
        meetingCoordinator.toggleRecording()
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
        refreshBotMenuItem()
    }

    private func refreshBotMenuItem() {
        let on = ChatbotEngine.shared.isEnabled
        botMenuItem?.state = on ? .on : .off
        botMenuItem?.title = on ? "WhatsApp Auto-Replies: On" : "WhatsApp Auto-Replies: Off"
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

    @objc func openOnboarding() {
        showOnboarding()
    }

    @objc func connectGoogleCalendar() {
        calendarWatcher.reauthenticate()
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
            let def = """
            You are Nikhil's friendly AI assistant. You're responding to WhatsApp messages while Nikhil is in a meeting. Be casual, warm, and helpful. Keep responses concise (1-3 sentences). Be honest -- say you're Nikhil's assistant, don't pretend to be him.
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
              "userName": "Nikhil",
              "waOwnName": "Nikhil Dhanda",
              "language": "auto"
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
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Open settings.json")
        alert.runModal()
        NSWorkspace.shared.open(url)
    }

    @objc func quitApp() { NSApp.terminate(nil) }

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
