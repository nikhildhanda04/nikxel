import AppKit
import ApplicationServices

/// Who is in the Google Meet and who is talking, read from the browser's
/// accessibility tree once a second while a meeting records. No extension and
/// no captions: Meet already marks the tile of whoever is speaking, and the
/// tile carries the person's name. Emails come from the calendar invite
/// (`attendees`), since Meet never shows them.
///
/// Turns into the "[Google Meet]" header and per-line names TranscriptMerger
/// puts in the transcript, so the summary names people instead of guessing.
final class MeetSpeakers {
    static let shared = MeetSpeakers()

    /// Meet's class names are generated and change between Meet releases.
    /// As of Nov 2026: a participant tile, and the class a tile has while that
    /// person is talking. If a whole meeting goes by without either, the log
    /// says so -- that's the sign these need updating.
    static let tileClass = "dkjMxf", speakingClass = "kssMZb"

    /// Chromium browsers and Safari, which all expose page content to
    /// accessibility clients (Nikxel already has Accessibility access).
    private static let browsers = [
        "company.thebrowser.dia", "company.thebrowser.Browser", "com.google.Chrome",
        "com.brave.Browser", "com.microsoft.edgemac", "com.apple.Safari",
    ]

    struct Result {
        var code: String?
        var names: [String] = []
        /// Seconds from the recording's start, and who Meet showed talking.
        var spans: [(start: Double, end: Double, name: String)] = []
    }

    private let queue = DispatchQueue(label: "nikxel.meet")
    private var timer: DispatchSourceTimer?
    private var started = Date()
    private var web: AXUIElement?
    private var result = Result()
    private var talking: (name: String, since: Double)?
    private var enabledPids = Set<pid_t>()

    func start() {
        queue.async {
            self.timer?.cancel()
            self.started = Date(); self.web = nil; self.result = Result(); self.talking = nil
            let t = DispatchSource.makeTimerSource(queue: self.queue)
            t.schedule(deadline: .now(), repeating: 1)
            t.setEventHandler { [weak self] in self?.tick() }
            t.resume()
            self.timer = t
        }
    }

    func stop() -> Result {
        queue.sync {
            timer?.cancel(); timer = nil
            closeSpan(at: Date().timeIntervalSince(started))
            if result.code != nil {
                cblog("MeetSpeakers: \(result.code!) — \(result.names.count) joined, \(result.spans.count) speaking turns")
                if result.names.isEmpty || result.spans.isEmpty {
                    cblog("MeetSpeakers: no \(result.names.isEmpty ? "tiles" : "speaking highlight") found; Meet's class names may have changed")
                }
            }
            return result
        }
    }

    private func tick() {
        let now = Date().timeIntervalSince(started)
        if let w = web, attr(w, kAXRoleAttribute) == nil { web = nil }  // tab closed or navigated
        if web == nil { web = findMeet() }
        guard let web = web else { return }

        var speaking: String?
        for tile in tiles(in: web) {
            guard let name = firstText(tile) else { continue }
            if !result.names.contains(name) { result.names.append(name) }
            if speaking == nil, classes(tile).contains(Self.speakingClass) { speaking = name }
        }
        if speaking != talking?.name {
            closeSpan(at: now)
            if let s = speaking { talking = (s, now) }
        }
    }

    private func closeSpan(at t: Double) {
        if let cur = talking, t > cur.since { result.spans.append((cur.since, t, cur.name)) }
        talking = nil
    }

    /// The Meet tab's web area. Only found while its window is on the current
    /// desktop; once found, it keeps being read from wherever it is.
    private func findMeet() -> AXUIElement? {
        for app in NSWorkspace.shared.runningApplications
            where app.bundleIdentifier.map(Self.browsers.contains) == true {
            let ax = AXUIElementCreateApplication(app.processIdentifier)
            // Chromium builds its page tree only once an assistive app asks.
            if enabledPids.insert(app.processIdentifier).inserted {
                AXUIElementSetAttributeValue(ax, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
            }
            for window in (attr(ax, kAXWindowsAttribute) as? [AXUIElement]) ?? [] {
                if let web = meetArea(window, depth: 0) {
                    let title = attr(web, kAXTitleAttribute) as? String ?? ""
                    result.code = title.components(separatedBy: " - ").last.flatMap { $0.contains("-") ? $0 : nil }
                    return web
                }
            }
        }
        return nil
    }

    private func meetArea(_ e: AXUIElement, depth: Int) -> AXUIElement? {
        if attr(e, kAXRoleAttribute) as? String == "AXWebArea" {
            return (attr(e, kAXTitleAttribute) as? String)?.hasPrefix("Meet - ") == true ? e : nil
        }
        guard depth < 30 else { return nil }
        for c in children(e) { if let f = meetArea(c, depth: depth + 1) { return f } }
        return nil
    }

    private func tiles(in e: AXUIElement, depth: Int = 0) -> [AXUIElement] {
        if classes(e).contains(Self.tileClass) { return [e] }
        guard depth < 40 else { return [] }
        return children(e).flatMap { tiles(in: $0, depth: depth + 1) }
    }

    /// A tile's only text is its person's name.
    private func firstText(_ e: AXUIElement, depth: Int = 0) -> String? {
        if attr(e, kAXRoleAttribute) as? String == kAXStaticTextRole,
           let v = (attr(e, kAXValueAttribute) as? String)?.trimmingCharacters(in: .whitespaces), !v.isEmpty { return v }
        guard depth < 20 else { return nil }
        for c in children(e) { if let t = firstText(c, depth: depth + 1) { return t } }
        return nil
    }

    private func attr(_ e: AXUIElement, _ name: String) -> CFTypeRef? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success ? v : nil
    }
    private func children(_ e: AXUIElement) -> [AXUIElement] { (attr(e, kAXChildrenAttribute) as? [AXUIElement]) ?? [] }
    private func classes(_ e: AXUIElement) -> [String] { (attr(e, "AXDOMClassList") as? [String]) ?? [] }

    // MARK: - Emails

    /// Name → email from the calendar event whose Meet link has `code`.
    /// Blocks up to ~10s; call off main. Empty without a Google connection.
    static func emails(code: String, around date: Date) -> [String: String] {
        let done = DispatchSemaphore(value: 0)
        var attendees: [[String: Any]] = []
        GoogleAuth.shared.withAccessToken { token in
            guard let token = token else { done.signal(); return }
            let iso = ISO8601DateFormatter()
            var c = URLComponents(string: "https://www.googleapis.com/calendar/v3/calendars/primary/events")!
            c.queryItems = [
                URLQueryItem(name: "timeMin", value: iso.string(from: date.addingTimeInterval(-12 * 3600))),
                URLQueryItem(name: "timeMax", value: iso.string(from: date.addingTimeInterval(12 * 3600))),
                URLQueryItem(name: "singleEvents", value: "true"),
                URLQueryItem(name: "maxResults", value: "100"),
            ]
            var req = URLRequest(url: c.url!)
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            URLSession.shared.dataTask(with: req) { data, _, _ in
                let items = (data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any])?["items"] as? [[String: Any]] ?? []
                let event = items.first { ($0["hangoutLink"] as? String)?.hasSuffix(code) == true }
                attendees = event?["attendees"] as? [[String: Any]] ?? []
                done.signal()
            }.resume()
        }
        _ = done.wait(timeout: .now() + 10)
        var out: [String: String] = [:]
        for a in attendees {
            guard let email = a["email"] as? String else { continue }
            out[(a["displayName"] as? String) ?? email] = email
        }
        return out
    }

    /// The email for a name Meet showed: the invite's display name, or an
    /// address whose local part has their first name ("prince@…" for Prince Choudhary).
    static func email(for name: String, in emails: [String: String]) -> String? {
        if let e = emails.first(where: { $0.key.caseInsensitiveCompare(name) == .orderedSame })?.value { return e }
        guard let first = name.split(separator: " ").first?.lowercased(), first.count >= 3 else { return nil }
        let hits = emails.values.filter { $0.lowercased().split(separator: "@").first?.contains(first) == true }
        return hits.count == 1 ? hits[0] : nil
    }
}
