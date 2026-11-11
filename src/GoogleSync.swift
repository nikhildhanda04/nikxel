import Foundation
import Cocoa

/// Turns a finished meeting note into Google Tasks and follow-up Google
/// Calendar events (with a Meet link).
///
/// It reads the Markdown the agent already wrote rather than asking the model
/// again: `## Action Items` and `## Follow-Up Meetings` are emitted in a fixed,
/// parseable line format for exactly this reason. A second LLM pass would cost
/// another minute and could invent items the note doesn't contain.
///
/// Nothing is ever pushed without the user saying yes to a dialog that lists
/// every item first -- this writes into somebody's real todo list and calendar.
enum GoogleSync {

    // MARK: - Parsed shapes

    struct ActionItem: Equatable {
        var title: String
        var owner: String
        var due: Date?

        /// Owner with the "(Me)" marker removed. The Speakers section labels
        /// the user as "Jake (Me)", so that -- not a bare first name -- is what
        /// actually lands in the Owner field, and comparing it raw against the
        /// user's name never matched.
        var normalizedOwner: String {
            owner.replacingOccurrences(of: "(Me)", with: "", options: .caseInsensitive)
                .trimmingCharacters(in: .whitespaces)
        }

        /// True when this is the user's own task, or nobody's.
        func isMine(ownName: String) -> Bool {
            let o = normalizedOwner
            return o.isEmpty
                || o.caseInsensitiveCompare(ownName) == .orderedSame
                || o.caseInsensitiveCompare("Me") == .orderedSame
                || o.caseInsensitiveCompare("Unassigned") == .orderedSame
        }

        /// Other people's tasks get their name up front, so a glance at the
        /// Google Tasks list shows whose it is -- Tasks has no assignee field.
        func taskTitle(ownName: String) -> String {
            isMine(ownName: ownName) ? title : "[\(normalizedOwner)] \(title)"
        }
    }

    struct FollowUp: Equatable {
        var title: String
        var start: Date
        var durationMin: Int
        var with: String
    }

    // MARK: - Parsing

    /// `- [ ] **Task** — Owner: Priya — Due: 2026-11-12`
    ///
    /// Fields are found from the right so an em dash inside the task text
    /// ("Ship the API — not the docs — by Friday") doesn't split the title.
    static func parseActionItems(_ markdown: String, tz: TimeZone = .current) -> [ActionItem] {
        var items: [ActionItem] = []
        for raw in section(markdown, heading: "Action Items").components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("- [ ]") || line.hasPrefix("- [x]") else { continue }
            var body = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)

            var due: Date?
            if let r = body.range(of: "— Due:", options: .backwards) {
                due = parseDay(String(body[r.upperBound...]), tz: tz)
                body = String(body[..<r.lowerBound])
            }
            var owner = ""
            if let r = body.range(of: "— Owner:", options: .backwards) {
                owner = String(body[r.upperBound...]).trimmingCharacters(in: .whitespaces)
                body = String(body[..<r.lowerBound])
            }
            if owner.caseInsensitiveCompare("Unassigned") == .orderedSame { owner = "" }

            let title = cleanInline(body)
            guard !title.isEmpty else { continue }
            // The prompt's own "no tasks" placeholder, not a task.
            if title.lowercased().hasPrefix("none") { continue }
            items.append(ActionItem(title: title, owner: owner, due: due))
        }
        return items
    }

    /// `- **Design review** — When: 2026-11-12 15:30 — Duration: 45 min — With: Priya, Rohan`
    ///
    /// Only lines with a concrete date AND time become events. "Not specified"
    /// is left alone on purpose: inventing a slot in someone's calendar is
    /// worse than not creating the event at all.
    static func parseFollowUps(_ markdown: String, tz: TimeZone = .current) -> [FollowUp] {
        var ups: [FollowUp] = []
        for raw in section(markdown, heading: "Follow-Up Meetings").components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("- ") else { continue }
            var body = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)

            var with = ""
            if let r = body.range(of: "— With:", options: .backwards) {
                with = String(body[r.upperBound...]).trimmingCharacters(in: .whitespaces)
                body = String(body[..<r.lowerBound])
            }
            var duration = 30
            if let r = body.range(of: "— Duration:", options: .backwards) {
                let digits = String(body[r.upperBound...]).filter { $0.isNumber }
                if let n = Int(digits), n > 0, n <= 8 * 60 { duration = n }
                body = String(body[..<r.lowerBound])
            }
            var start: Date?
            if let r = body.range(of: "— When:", options: .backwards) {
                start = parseMoment(String(body[r.upperBound...]), tz: tz)
                body = String(body[..<r.lowerBound])
            }

            let title = cleanInline(body)
            guard !title.isEmpty, !title.lowercased().hasPrefix("none"), let start = start else { continue }
            if with.caseInsensitiveCompare("Not specified") == .orderedSame { with = "" }
            ups.append(FollowUp(title: title, start: start, durationMin: duration, with: with))
        }
        return ups
    }

    /// Everything under `## <heading>` up to the next `##`. Returns "" when the
    /// note has no such section -- an older note, or a user whose summary style
    /// told the model to drop it.
    static func section(_ markdown: String, heading: String) -> String {
        var out: [String] = []
        var inside = false
        for line in markdown.components(separatedBy: .newlines) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("## ") {
                let name = String(t.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                inside = name.caseInsensitiveCompare(heading) == .orderedSame
                continue
            }
            // A deeper heading (### inside Agent Prompts) stays part of its section.
            if inside { out.append(line) }
        }
        return out.joined(separator: "\n")
    }

    /// Strips bold/italic/code markers and surrounding punctuation left behind
    /// after the trailing fields are sliced off.
    private static func cleanInline(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespaces)
        t = t.replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "`", with: "")
        while let last = t.last, last == "—" || last == "-" || last == "," || last == ":" {
            t = String(t.dropLast()).trimmingCharacters(in: .whitespaces)
        }
        return t.trimmingCharacters(in: .whitespaces)
    }

    /// "2026-11-12" -> that day. Anything else (prose like "next Friday", or
    /// "Not specified") -> nil, and the task is created without a due date.
    static func parseDay(_ s: String, tz: TimeZone = .current) -> Date? {
        let t = s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "*", with: "")
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = tz
        df.dateFormat = "yyyy-MM-dd"
        return df.date(from: String(t.prefix(10)))
    }

    /// "2026-11-12 15:30" or "2026-11-12T15:30". A date with no time is not a
    /// moment -- a follow-up needs both, so this returns nil rather than
    /// defaulting to midnight.
    static func parseMoment(_ s: String, tz: TimeZone = .current) -> Date? {
        let t = s.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "*", with: "")
            .replacingOccurrences(of: "T", with: " ")
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = tz
        df.dateFormat = "yyyy-MM-dd HH:mm"
        return df.date(from: String(t.prefix(16)))
    }

    // MARK: - Already-synced markers

    private static var syncedDir: URL {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".nikxel/synced", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Keyed by the note's filename stem, so regenerating or re-opening a
    /// summary can't quietly duplicate everything in the user's todo list.
    static func isSynced(_ noteURL: URL) -> Bool {
        FileManager.default.fileExists(atPath: markerURL(noteURL).path)
    }

    private static func markerURL(_ noteURL: URL) -> URL {
        syncedDir.appendingPathComponent(noteURL.deletingPathExtension().lastPathComponent + ".json")
    }

    private static func markSynced(_ noteURL: URL, tasks: Int, events: Int) {
        let payload: [String: Any] = ["tasks": tasks, "events": events, "at": Date().timeIntervalSince1970]
        if let data = try? JSONSerialization.data(withJSONObject: payload) {
            try? data.write(to: markerURL(noteURL))
        }
    }

    // MARK: - Entry point

    /// Reads `noteURL`, and if it contains anything actionable, asks the user
    /// whether to push it to Google. Call on the main thread.
    static func offer(noteURL: URL) {
        guard NikxelSettings.googleSyncEnabled else { return }
        guard !isSynced(noteURL) else { return }
        // saveOutput hands back the .pdf/.docx when that's the chosen note
        // format. The Markdown is always written alongside it, and it is the
        // only one of the three this can parse.
        let mdURL = noteURL.pathExtension.lowercased() == "md"
            ? noteURL
            : noteURL.deletingPathExtension().appendingPathExtension("md")
        guard let md = try? String(contentsOf: mdURL, encoding: .utf8) else { return }

        let tasks = parseActionItems(md)
        let events = parseFollowUps(md)
        guard !tasks.isEmpty || !events.isEmpty else { return }

        // Don't nag someone who has never connected Google -- there is nothing
        // they can usefully do with the dialog.
        guard GoogleAuth.shared.isAuthorized else { return }

        let missing = ["https://www.googleapis.com/auth/tasks",
                       "https://www.googleapis.com/auth/calendar.events"]
            .filter { !GoogleAuth.shared.hasScope($0) }
        if !missing.isEmpty {
            NikxelView.ask(icon: "🔑", title: "Reconnect Google to send these to Tasks", lines: [
                "This summary has \(tasks.count) task\(tasks.count == 1 ? "" : "s")\(events.isEmpty ? "" : " and \(events.count) follow-up meeting\(events.count == 1 ? "" : "s")").",
                "Google was connected before Nikxel could write to it. One click re-grants.",
            ], buttons: [("Reconnect", { GoogleAuth.shared.reauthenticate() }), ("Not now", {})])
            return
        }

        // The card shows 5 lines; the full list is in the note ("Open note").
        let ownName = NikxelSettings.userName
        var lines: [String] = events.map { "📅 \($0.title) — \(shortMoment($0.start)), \($0.durationMin) min" }
        for t in tasks {
            let when = t.due.map { " (due \(shortDay($0)))" } ?? ""
            lines.append("\(t.taskTitle(ownName: ownName))\(when)")
        }
        let total = lines.count
        if total > 5 { lines = Array(lines.prefix(4)) + ["…and \(total - 4) more"] }

        NikxelView.ask(icon: "✅", title: "Send this meeting's tasks to Google?", lines: lines, bulleted: true,
                       buttons: [
                        (events.isEmpty ? "Add \(tasks.count) task\(tasks.count == 1 ? "" : "s")" : "Add to Google",
                         { push(tasks: tasks, events: events, noteURL: mdURL) }),
                        ("Not now", {}),
                        ("Open note", { NSWorkspace.shared.open(noteURL) }),   // the format they chose, not the .md
                       ])
    }

    private static func shortDay(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "d MMM"; return f.string(from: d)
    }

    private static func shortMoment(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "d MMM, HH:mm"; return f.string(from: d)
    }

    // MARK: - Writing to Google

    private static func push(tasks: [ActionItem], events: [FollowUp], noteURL: URL) {
        GoogleAuth.shared.withAccessToken { token in
            guard let token = token else {
                DispatchQueue.main.async {
                    GoogleAuth.shared.showAlert("Couldn't refresh your Google login. Try Connect Google Account from the menu.")
                }
                return
            }
            let ownName = NikxelSettings.userName
            let group = DispatchGroup()
            let lock = NSLock()
            var created = 0
            var failures: [String] = []
            var meetLinks: [String] = []

            for t in tasks {
                group.enter()
                createTask(t, ownName: ownName, note: noteURL, token: token) { err in
                    lock.lock()
                    if let err = err { failures.append("task “\(t.title)”: \(err)") } else { created += 1 }
                    lock.unlock()
                    group.leave()
                }
            }
            for e in events {
                group.enter()
                createEvent(e, note: noteURL, token: token) { link, err in
                    lock.lock()
                    if let err = err { failures.append("meeting “\(e.title)”: \(err)") }
                    else { created += 1; if let link = link { meetLinks.append("\(e.title): \(link)") } }
                    lock.unlock()
                    group.leave()
                }
            }

            group.notify(queue: .main) {
                // Mark synced on partial success too: re-running would duplicate
                // everything that did land, which is worse than leaving the few
                // failures to be added by hand.
                if created > 0 { markSynced(noteURL, tasks: tasks.count, events: events.count) }
                var msg = created > 0 ? "Added \(created) item\(created == 1 ? "" : "s") to Google." : "Nothing was added."
                if !meetLinks.isEmpty { msg += "\n\nMeet links:\n" + meetLinks.joined(separator: "\n") }
                if !failures.isEmpty { msg += "\n\nFailed:\n" + failures.prefix(5).joined(separator: "\n") }
                GoogleAuth.shared.showAlert(msg)
            }
        }
    }

    // MARK: - Tasks out of WhatsApp chats

    /// Why a chat task couldn't be filed, when it's something the user can
    /// actually fix.
    enum ChatTaskBlock {
        /// Connected before Nikxel could write; one click re-grants.
        case needsReconnect
        /// The Tasks API isn't switched on for the OAuth project. Nothing in
        /// Nikxel can do this -- it's a toggle in the Cloud console.
        case apiDisabled(consoleURL: String?)
        case other(String)
    }

    /// Fired at most once per launch when a chat task is blocked. Wired to the
    /// avatar card in NikxelApp -- without it the user's tasks vanish into a log
    /// file they have no reason to open.
    static var onChatTaskBlocked: ((ChatTaskBlock) -> Void)?
    private static var warnedTaskBlock = false

    private static func reportBlocked(_ b: ChatTaskBlock) {
        guard !warnedTaskBlock else { return }
        warnedTaskBlock = true
        DispatchQueue.main.async { onChatTaskBlocked?(b) }
    }

    /// Google answers a switched-off API with a 403 naming the console page
    /// that turns it on. Lift that URL so the card can open it directly.
    static func consoleURL(in message: String) -> String? {
        guard let r = message.range(of: "https://console.developers.google.com/") else { return nil }
        let tail = message[r.lowerBound...]
        let cut = tail.firstIndex(where: { $0 == " " || $0 == "\n" }) ?? tail.endIndex
        return String(tail[..<cut])
    }

    /// Whether an API error means "this API is not switched on for the project".
    static func isAPIDisabled(_ message: String) -> Bool {
        let m = message.lowercased()
        return m.contains("has not been used in project") || m.contains("is disabled")
    }

    /// File one task that came out of a chat message.
    ///
    /// Silent, unlike `offer`: a modal per WhatsApp message would be worse than
    /// the problem it solves, and this only ever writes to the user's own task
    /// list. No-ops -- with a log line, not an alert -- when Google isn't
    /// connected or was connected before Nikxel could write, so the bot never
    /// nags about a feature the user hasn't set up.
    ///
    /// ponytail: title only, no due date. Any "by Friday" the contact wrote
    /// stays inside the title, which Google Tasks shows in full. Parsing a date
    /// out of chat prose is a bigger job than the value, and a task filed under
    /// the wrong Friday is worse than one with no date at all.
    static func createChatTask(title: String, from contact: String,
                               completion: ((String?) -> Void)? = nil) {
        guard NikxelSettings.waChatTasks else { completion?("chat tasks off"); return }
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { completion?("empty title"); return }
        guard GoogleAuth.shared.isAuthorized else {
            cblog("GoogleSync: chat task '\(clean)' not filed — no Google account connected")
            completion?("not connected"); return
        }
        guard GoogleAuth.shared.hasScope("https://www.googleapis.com/auth/tasks") else {
            cblog("GoogleSync: chat task '\(clean)' not filed — reconnect Google to grant Tasks access")
            reportBlocked(.needsReconnect)
            completion?("missing scope"); return
        }
        GoogleAuth.shared.withAccessToken { token in
            guard let token = token else {
                cblog("GoogleSync: chat task '\(clean)' not filed — couldn't refresh the Google login")
                completion?("no token"); return
            }
            post("https://tasks.googleapis.com/tasks/v1/lists/@default/tasks",
                 body: ["title": clean,
                        "notes": "From a WhatsApp message from \(contact)."],
                 token: token) { _, err in
                if let err = err {
                    cblog("GoogleSync: chat task '\(clean)' failed — \(err)")
                    // Measured: a project that has never used Tasks answers 403
                    // with exactly this, and every task after it would have
                    // failed the same silent way.
                    reportBlocked(isAPIDisabled(err)
                        ? .apiDisabled(consoleURL: consoleURL(in: err))
                        : .other(err))
                } else {
                    cblog("GoogleSync: filed chat task '\(clean)' (from \(contact))")
                }
                completion?(err)
            }
        }
    }

    private static func createTask(_ item: ActionItem, ownName: String, note: URL, token: String,
                                   completion: @escaping (String?) -> Void) {
        var body: [String: Any] = ["title": item.taskTitle(ownName: ownName)]
        var notes = "From \(note.lastPathComponent)"
        if !item.isMine(ownName: ownName) { notes = "Owner: \(item.normalizedOwner)\n" + notes }
        body["notes"] = notes
        if let due = item.due {
            // Google Tasks stores a date only; the time part is ignored but the
            // field still has to be full RFC3339.
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone(secondsFromGMT: 0)
            f.dateFormat = "yyyy-MM-dd'T'00:00:00'Z'"
            body["due"] = f.string(from: due)
        }
        post("https://tasks.googleapis.com/tasks/v1/lists/@default/tasks",
             body: body, token: token) { _, err in completion(err) }
    }

    private static func createEvent(_ e: FollowUp, note: URL, token: String,
                                    completion: @escaping (String?, String?) -> Void) {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        iso.timeZone = TimeZone.current
        var description = "Follow-up from \(note.lastPathComponent)."
        // Names only -- the transcript never contains email addresses, and
        // guessing one would invite a stranger to the user's meeting.
        if !e.with.isEmpty { description += "\n\nDiscussed with: \(e.with). Invite them yourself — Nikxel only had their names." }

        let body: [String: Any] = [
            "summary": e.title,
            "description": description,
            "start": ["dateTime": iso.string(from: e.start), "timeZone": TimeZone.current.identifier],
            "end": ["dateTime": iso.string(from: e.start.addingTimeInterval(Double(e.durationMin * 60))),
                    "timeZone": TimeZone.current.identifier],
            "conferenceData": [
                "createRequest": [
                    "requestId": UUID().uuidString,
                    "conferenceSolutionKey": ["type": "hangoutsMeet"]
                ]
            ]
        ]
        post("https://www.googleapis.com/calendar/v3/calendars/primary/events?conferenceDataVersion=1",
             body: body, token: token) { obj, err in
            completion(obj?["hangoutLink"] as? String, err)
        }
    }

    // MARK: - Calls agreed in WhatsApp

    static var canScheduleMeets: Bool {
        GoogleAuth.shared.isAuthorized
            && GoogleAuth.shared.hasScope("https://www.googleapis.com/auth/calendar.events")
    }

    private static let eventsURL = "https://www.googleapis.com/calendar/v3/calendars/primary/events"

    /// No Google account: a Jitsi room needs no account or API to create --
    /// the link is the room. Random name so it can't be guessed.
    /// ponytail: public meet.jit.si, whose first joiner signs in (Google,
    /// GitHub or Facebook) to open the room. Point it at a self-hosted or
    /// login-free Jitsi instance if that ever bites.
    static func jitsiLink() -> String {
        "https://meet.jit.si/Nikxel-" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(16)
    }

    /// A 30-minute calendar event with a Meet link, for a call agreed with a
    /// WhatsApp contact. Calls back with the link and the event id (to move or
    /// delete it). Without Google -- or if Google fails -- the link is a Jitsi
    /// room and the id is nil, so there is no event to move or delete.
    static func createChatMeet(with contact: String, at start: Date,
                               completion: @escaping (_ link: String?, _ eventId: String?) -> Void) {
        guard canScheduleMeets else { completion(jitsiLink(), nil); return }
        GoogleAuth.shared.withAccessToken { token in
            guard let token = token else { completion(jitsiLink(), nil); return }
            post(eventsURL + "?conferenceDataVersion=1", body: [
                "summary": "Call with \(contact)",
                "description": "Agreed over WhatsApp. Nikxel sends \(contact) the Meet link at the start time.",
                "start": eventTime(start), "end": eventTime(start.addingTimeInterval(30 * 60)),
                "conferenceData": ["createRequest": ["requestId": UUID().uuidString,
                                                     "conferenceSolutionKey": ["type": "hangoutsMeet"]]],
            ], token: token) { obj, err in
                if let err = err { cblog("GoogleSync: Meet for '\(contact)' failed — \(err); using Jitsi") }
                guard let link = obj?["hangoutLink"] as? String else { completion(jitsiLink(), nil); return }
                completion(link, obj?["id"] as? String)
            }
        }
    }

    /// Same event, same link, new time.
    static func moveChatMeet(eventId: String, to start: Date) {
        GoogleAuth.shared.withAccessToken { token in
            guard let token = token else { return }
            post("\(eventsURL)/\(eventId)", method: "PATCH",
                 body: ["start": eventTime(start), "end": eventTime(start.addingTimeInterval(30 * 60))],
                 token: token) { _, err in
                if let err = err { cblog("GoogleSync: moving Meet \(eventId) failed — \(err)") }
            }
        }
    }

    static func deleteChatMeet(eventId: String) {
        GoogleAuth.shared.withAccessToken { token in
            guard let token = token else { return }
            post("\(eventsURL)/\(eventId)", method: "DELETE", body: nil, token: token) { _, err in
                if let err = err { cblog("GoogleSync: deleting Meet \(eventId) failed — \(err)") }
            }
        }
    }

    private static func eventTime(_ d: Date) -> [String: String] {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        iso.timeZone = TimeZone.current
        return ["dateTime": iso.string(from: d), "timeZone": TimeZone.current.identifier]
    }

    private static func post(_ urlString: String, method: String = "POST", body: [String: Any]?, token: String,
                             completion: @escaping ([String: Any]?, String?) -> Void) {
        guard let url = URL(string: urlString) else {
            completion(nil, "could not build the request"); return
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let body = body {
            guard let data = try? JSONSerialization.data(withJSONObject: body) else {
                completion(nil, "could not build the request"); return
            }
            req.httpBody = data
        }
        URLSession.shared.dataTask(with: req) { data, resp, err in
            if let err = err { completion(nil, err.localizedDescription); return }
            let obj = data.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code == 401 { GoogleAuth.shared.invalidateAccessToken() }
            guard (200..<300).contains(code) else {
                let inner = (obj?["error"] as? [String: Any])?["message"] as? String
                completion(obj, inner ?? "HTTP \(code)")
                return
            }
            completion(obj, nil)
        }.resume()
    }
}
