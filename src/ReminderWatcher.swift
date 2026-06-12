import Foundation
import EventKit
import Cocoa

struct PendingReminder {
    let id: String
    let title: String
}

/// Surfaces incomplete reminders the user hasn't seen yet on this Mac.
///
/// The use case: user is away from the laptop, jots a reminder via Siri / iPhone /
/// Watch. When they next open the Mac, those new reminders should bubble up. So
/// we don't filter to "due today" — we track which reminder IDs Nikxel has ever
/// shown, persist that across launches, and only bubble unseen ones.
///
/// On first ever launch we bootstrap: mark everything currently incomplete as
/// seen WITHOUT bubbling, so the user isn't bombarded with years of backlog.
/// From that point on, anything new (added on another device, added in
/// Reminders.app, etc.) shows up the next time we fetch.
class ReminderWatcher {
    let store = EKEventStore()
    var onReminder: ((PendingReminder) -> Void)?

    private var timer: Timer?
    private var changeObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    private var seenIDs: Set<String> = []
    private var lastFetch: TimeInterval = 0
    private var didShowDeniedAlert = false

    private let pollInterval: TimeInterval = 60
    private let changeDebounce: TimeInterval = 2
    private let seenKey = "nikxel.reminders.seenIDs"
    private let bootstrapKey = "nikxel.reminders.bootstrapDone"

    init() {
        if let arr = UserDefaults.standard.array(forKey: seenKey) as? [String] {
            seenIDs = Set(arr)
        }
    }

    deinit { stop() }

    // MARK: - Lifecycle

    func start() {
        requestAccess { [weak self] granted in
            guard let self = self else { return }
            if granted {
                self.beginPolling()
                self.observeChanges()
                self.observeWake()
            } else {
                self.showDeniedAlertIfNeeded()
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if let obs = changeObserver {
            NotificationCenter.default.removeObserver(obs)
            changeObserver = nil
        }
        if let obs = wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
            wakeObserver = nil
        }
    }

    /// Re-runs the access request — used by "Connect Apple Reminders…" if the
    /// user originally denied and changed their mind.
    func reauthenticate() {
        didShowDeniedAlert = false
        requestAccess { [weak self] granted in
            guard let self = self else { return }
            if granted {
                self.beginPolling()
                self.observeChanges()
                self.observeWake()
            } else {
                self.showSystemSettingsAlert()
            }
        }
    }

    // MARK: - Access

    private func requestAccess(completion: @escaping (Bool) -> Void) {
        let cb: (Bool) -> Void = { granted in DispatchQueue.main.async { completion(granted) } }
        if #available(macOS 14.0, *) {
            store.requestFullAccessToReminders { granted, _ in cb(granted) }
        } else {
            store.requestAccess(to: .reminder) { granted, _ in cb(granted) }
        }
    }

    private func showDeniedAlertIfNeeded() {
        guard !didShowDeniedAlert else { return }
        didShowDeniedAlert = true
        showSystemSettingsAlert()
    }

    private func showSystemSettingsAlert() {
        let alert = NSAlert()
        alert.messageText = "Apple Reminders access not granted"
        alert.informativeText = "Nikxel needs access to Reminders to surface tasks you added on other devices. Grant access in System Settings → Privacy & Security → Reminders."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    // MARK: - Polling / observers

    private func beginPolling() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            self?.fetchUnseenReminders()
        }
        fetchUnseenReminders()
    }

    private func observeChanges() {
        if changeObserver != nil { return }
        changeObserver = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged,
            object: store,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            let now = Date().timeIntervalSince1970
            if now - self.lastFetch < self.changeDebounce { return }
            self.fetchUnseenReminders()
        }
    }

    private func observeWake() {
        if wakeObserver != nil { return }
        // When the Mac wakes from sleep, iCloud will sync newly-added reminders
        // shortly after. Refetch immediately AND a bit later so we catch them
        // even if the change-notification doesn't fire reliably during wake.
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            self.fetchUnseenReminders()
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                self?.fetchUnseenReminders()
            }
        }
    }

    private func fetchUnseenReminders() {
        lastFetch = Date().timeIntervalSince1970
        let predicate = store.predicateForIncompleteReminders(
            withDueDateStarting: nil, ending: nil, calendars: nil
        )
        store.fetchReminders(matching: predicate) { [weak self] reminders in
            guard let self = self, let reminders = reminders else { return }
            DispatchQueue.main.async {
                self.processFetched(reminders)
            }
        }
    }

    private func processFetched(_ reminders: [EKReminder]) {
        let currentIDs = Set(reminders.map { $0.calendarItemIdentifier })

        // First ever run: silently mark every existing incomplete reminder as
        // seen so we don't dump the whole backlog on the user.
        let bootstrapped = UserDefaults.standard.bool(forKey: bootstrapKey)
        if !bootstrapped {
            seenIDs = currentIDs
            persistSeen()
            UserDefaults.standard.set(true, forKey: bootstrapKey)
            return
        }

        // Prune IDs we used to know about but that are no longer in the
        // incomplete set (completed, deleted, or due-date moved out of view).
        // Keeps the persisted set bounded over years of use.
        seenIDs.formIntersection(currentIDs)

        for r in reminders {
            let id = r.calendarItemIdentifier
            if seenIDs.contains(id) { continue }
            seenIDs.insert(id)
            let title = (r.title?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 } ?? "Reminder"
            onReminder?(PendingReminder(id: id, title: title))
        }
        persistSeen()
    }

    private func persistSeen() {
        UserDefaults.standard.set(Array(seenIDs), forKey: seenKey)
    }

    // MARK: - Complete

    /// Mark the reminder with the given calendarItemIdentifier as completed.
    func complete(id: String) {
        let predicate = store.predicateForIncompleteReminders(
            withDueDateStarting: nil, ending: nil, calendars: nil
        )
        store.fetchReminders(matching: predicate) { [weak self] reminders in
            guard let self = self, let reminders = reminders else { return }
            guard let r = reminders.first(where: { $0.calendarItemIdentifier == id }) else { return }
            r.isCompleted = true
            do {
                try self.store.save(r, commit: true)
            } catch {
                print("ReminderWatcher: failed to mark complete: \(error)")
            }
        }
    }
}
