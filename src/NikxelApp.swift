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
    private var reminderDismissTimer: Timer?
    private var muteMenuItem: NSMenuItem?
    private var recordMenuItem: NSMenuItem?
    private var modeNotesItem: NSMenuItem?
    private var modeMeetingItem: NSMenuItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        stateMachine = StateMachine()
        agentMonitor = AgentMonitor(stateMachine: stateMachine)
        inputHandler = InputHandler(stateMachine: stateMachine)

        window = NikxelWindow(stateMachine: stateMachine)
        inputHandler.nikxelView = window.nikxelView
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

        setupMenuBar()
        agentMonitor.startMonitoring()
        inputHandler.startMonitoring()
        calendarWatcher.start()
        reminderWatcher.start()
        // Trigger TCC prompt on launch so it's granted before user hits record
        meetingCoordinator.recorder.warmUpPermission()
    }

    func applicationWillTerminate(_ notification: Notification) {
        agentMonitor.stopMonitoring()
        inputHandler.stopMonitoring()
        calendarWatcher.stop()
        reminderWatcher.stop()
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

        let mute = NSMenuItem(title: "Mute Mic", action: #selector(toggleMicMute), keyEquivalent: "m")
        mute.target = self; menu.addItem(mute)
        self.muteMenuItem = mute
        refreshMuteMenuItem()

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

        let connectGCal = NSMenuItem(title: "Connect Google Calendar…", action: #selector(connectGoogleCalendar), keyEquivalent: "")
        connectGCal.target = self; menu.addItem(connectGCal)

        let connectReminders = NSMenuItem(title: "Connect Apple Reminders…", action: #selector(connectAppleReminders), keyEquivalent: "")
        connectReminders.target = self; menu.addItem(connectReminders)

        menu.addItem(NSMenuItem.separator())
        let quit = NSMenuItem(title: "Quit Nikxel", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self; menu.addItem(quit)
        statusItem.menu = menu
    }

    @objc func toggleVisibility() {
        if window.isVisible { window.orderOut(nil) }
        else { window.makeKeyAndOrderFront(nil) }
    }

    @objc func toggleRecording() {
        meetingCoordinator.toggleRecording()
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

    @objc func connectGoogleCalendar() {
        calendarWatcher.reauthenticate()
    }

    @objc func connectAppleReminders() {
        reminderWatcher.reauthenticate()
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
