import Foundation
import AppKit
import ApplicationServices
import CoreAudio

extension Notification.Name {
    static let meetingStateChanged = Notification.Name("meetingStateChanged")
}

class MeetingDetector {
    static let shared = MeetingDetector()

    private var timer: Timer?
    private var autoDetected = false
    /// What the auto-detection saw, for the "record it?" prompt: "a WhatsApp call", "Google Meet". nil when none.
    private(set) var source: String?
    /// Any other app holding the microphone (a voice recorder, a call app not
    /// in `callApps`), by name. Not a meeting -- it doesn't change
    /// `isInMeeting`, so the WhatsApp bot isn't put in meeting mode by
    /// dictation -- but Nikxel offers to record it all the same.
    private(set) var micApp: String?
    var onMicAppChanged: ((String?) -> Void)?

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
            // The mic first: one CoreAudio read says whether a call app has it open right now.
            // A browser holding the mic is named after the Meet window when one is showing.
            let meet = { Self.checkWindowTitles() || Self.checkArcTabs() }
            let (mic, other) = Self.micUsers()
            let source = mic == Self.browserCall ? (meet() ? "Google Meet" : mic) : mic ?? (meet() ? "Google Meet" : nil)
            DispatchQueue.main.async {
                guard let self else { return }
                self.source = source
                self.autoDetected = source != nil
                self.recomputeState()
                if other != self.micApp { self.micApp = other; self.onMicAppChanged?(other) }
            }
        }
    }

    /// Call apps by bundle-ID prefix (prefix, so their helper processes count too). Holding the mic
    /// open is what separates being on a call from merely having the app running.
    private static let callApps: [(String, String)] = [
        ("net.whatsapp.WhatsApp", "a WhatsApp call"), ("desktop.WhatsApp", "a WhatsApp call"),
        ("us.zoom.xos", "a Zoom call"), ("com.microsoft.teams", "a Teams call"),
        ("com.apple.FaceTime", "a FaceTime call"), ("com.tinyspeck.slackmacgap", "a Slack huddle"),
        ("com.hnc.Discord", "a Discord call"), ("Cisco-Systems.Spark", "a Webex call"),
        // Browsers (Arc and Dia share the company.thebrowser prefix): a web call — Meet, or Zoom/Teams on the web.
        ("company.thebrowser", browserCall), ("com.google.Chrome", browserCall), ("com.brave.Browser", browserCall),
        ("com.microsoft.edgemac", browserCall), ("com.apple.WebKit", browserCall), ("com.apple.Safari", browserCall),
    ]
    private static let browserCall = "a call in your browser"

    /// Holding the mic without it being a recording: Nikxel itself (its own
    /// recorder and chat mic), Siri and dictation.
    private static let ignoredMicApps = ["com.nikxel.", "com.apple.siri", "com.apple.assistant", "com.apple.corespeech",
                                         "com.apple.speechrecognitioncore", "com.apple.dictation", "com.apple.hearingaids"]

    /// Who has microphone input running, via CoreAudio's per-process objects (macOS 14.2+):
    /// the first call app, and the first other app by name.
    private static func micUsers() -> (call: String?, other: String?) {
        var other: String?
        func addr(_ sel: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
            AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        }
        let system = AudioObjectID(kAudioObjectSystemObject)
        var a = addr(kAudioHardwarePropertyProcessObjectList), size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &a, 0, nil, &size) == noErr, size > 0 else { return (nil, nil) }
        var procs = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &a, 0, nil, &size, &procs) == noErr else { return (nil, nil) }
        for p in procs {
            var running: UInt32 = 0, rs = UInt32(MemoryLayout<UInt32>.size)
            var ra = addr(kAudioProcessPropertyIsRunningInput)
            guard AudioObjectGetPropertyData(p, &ra, 0, nil, &rs, &running) == noErr, running != 0 else { continue }
            var bundle: Unmanaged<CFString>?, bs = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            var ba = addr(kAudioProcessPropertyBundleID)
            guard AudioObjectGetPropertyData(p, &ba, 0, nil, &bs, &bundle) == noErr,
                  let id = bundle?.takeRetainedValue() as String? else { continue }
            let lower = id.lowercased()   // helpers report lowercase IDs
            if let hit = callApps.first(where: { lower.hasPrefix($0.0.lowercased()) }) { return (hit.1, nil) }
            if other == nil, !ignoredMicApps.contains(where: { lower.hasPrefix($0) }) { other = appName(id) }
        }
        return (nil, other)
    }

    /// "Voice Memos" for com.apple.VoiceMemos: the running app's name, else the installed app's, else the ID's last part.
    private static func appName(_ bundleID: String) -> String {
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first, let name = app.localizedName { return name }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) { return url.deletingPathExtension().lastPathComponent }
        return bundleID.split(separator: ".").last.map(String.init) ?? bundleID
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
            "company.thebrowser.dia",      // Dia
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
