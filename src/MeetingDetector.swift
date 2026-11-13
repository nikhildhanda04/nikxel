import Foundation
import AppKit
import ApplicationServices

extension Notification.Name {
    static let meetingStateChanged = Notification.Name("meetingStateChanged")
}

class MeetingDetector {
    static let shared = MeetingDetector()

    private var timer: Timer?
    private var autoDetected = false

    /// When true, force `isInMeeting` regardless of auto-detection. Used for
    /// offline / in-person meetings where there's no Meet tab to detect.
    var manualOverride = false {
        didSet { if oldValue != manualOverride { recomputeState() } }
    }

    private(set) var isInMeeting = false {
        didSet {
            if oldValue != isInMeeting {
                NSLog("MeetingDetector: state -> \(isInMeeting ? "IN MEETING" : "not in meeting") (auto=\(autoDetected) manual=\(manualOverride))")
                NotificationCenter.default.post(name: .meetingStateChanged, object: nil)
            }
        }
    }

    private func recomputeState() {
        isInMeeting = autoDetected || manualOverride
    }

    func start() {
        check()
        timer = Timer.scheduledTimer(withTimeInterval: 8, repeats: true) { [weak self] _ in
            self?.check()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        autoDetected = false
        manualOverride = false
        isInMeeting = false
    }

    private func check() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            // Titles first: one AX read per window. The Arc scan is an Apple
            // Event per tab, so it only runs when the titles found nothing.
            let detected = Self.checkWindowTitles() || Self.checkArcTabs()
            DispatchQueue.main.async {
                self?.autoDetected = detected
                self?.recomputeState()
            }
        }
    }

    private static func checkArcTabs() -> Bool {
        // Don't trigger Arc to launch if it isn't already running — `tell
        // application "Arc"` would otherwise cold-boot the browser.
        let arcRunning = NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == "company.thebrowser.Browser"
        }
        guard arcRunning else { return false }

        // Iterate windows × tabs explicitly. The `every tab of every window`
        // form returns a list-of-lists whose coercion to string is unreliable
        // across Arc builds.
        let script = """
        tell application "Arc"
            set foundMeet to false
            repeat with w in windows
                repeat with t in tabs of w
                    set u to URL of t
                    if u contains "meet.google.com" then
                        set foundMeet to true
                        exit repeat
                    end if
                end repeat
                if foundMeet then exit repeat
            end repeat
            if foundMeet then return "true"
            return "false"
        end tell
        """
        return runAppleScript(script) == "true"
    }

    private static func checkWindowTitles() -> Bool {
        let bundleIDs = [
            "company.thebrowser.Browser",  // Arc
            "com.google.Chrome",           // Chrome
            "com.apple.Safari",            // Safari
            "com.brave.Browser",           // Brave
            "com.microsoft.edgemac"        // Edge
        ]

        // Every instance, not the first: Nikxel's own WhatsApp Chrome shares
        // Chrome's bundle ID and could hide the user's real one.
        for app in NSWorkspace.shared.runningApplications
            where app.bundleIdentifier.map(bundleIDs.contains) == true {

            let axApp = AXUIElementCreateApplication(app.processIdentifier)
            var windowRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowRef) == .success,
                  let windows = windowRef as? [AXUIElement] else { continue }

            for window in windows {
                var titleRef: CFTypeRef?
                AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleRef)

                if let title = titleRef as? String,
                   (title.contains("Google Meet") || title.contains("meet.google.com") || title.hasPrefix("Meet -")) {
                    return true
                }

                // Arc doesn't put the full URL in the window title ("Meet - sog-xwzk-syz"),
                // but the AXDocument / AXURL attribute often carries the page URL.
                var urlRef: CFTypeRef?
                if AXUIElementCopyAttributeValue(window, kAXURLAttribute as CFString, &urlRef) == .success,
                   let url = urlRef as? String,
                   url.contains("meet.google.com") {
                    return true
                }
                // kAXDocumentAttribute is another common name for the URL.
                var docRef: CFTypeRef?
                if AXUIElementCopyAttributeValue(window, kAXDocumentAttribute as CFString, &docRef) == .success,
                   let doc = docRef as? String,
                   doc.contains("meet.google.com") {
                    return true
                }
            }
        }
        return false
    }

    private static var loggedAppleScriptError = false
    private static func runAppleScript(_ script: String) -> String? {
        guard let appleScript = NSAppleScript(source: script) else { return nil }
        var error: NSDictionary?
        let result = appleScript.executeAndReturnError(&error)
        if let error = error {
            // -1743 = "not authorized to send Apple events to <target>" — the
            // user hasn't granted Automation permission yet (or Info.plist is
            // missing NSAppleEventsUsageDescription, in which case macOS
            // silently denies without prompting). Log once so this is
            // diagnosable from Console.app instead of failing silently.
            if !loggedAppleScriptError {
                loggedAppleScriptError = true
                NSLog("MeetingDetector: AppleScript failed (\(error)). If error code -1743, grant Automation permission for Arc in System Settings → Privacy & Security → Automation.")
            }
            return nil
        }
        return result.stringValue
    }
}
