import Foundation

/// "Share to project" on a meeting page (PageShare /projects and /share-project).
/// Sends the minutes beside the page (<stem>.md, minus its Client Summary) to one
/// of the user's dashboard projects. Mirrors projectShare.ts.
enum ProjectShare {
    /// What a share of the minutes page `file` sends: the stem is the meeting id,
    /// the "# " line the title, the stem's stamp (NoteName) the date.
    /// nil when the page isn't saved meeting minutes.
    static func meeting(_ file: URL) -> (id: String, title: String, date: String, body: String)? {
        guard file.deletingLastPathComponent().lastPathComponent == "meetings",
              let md = try? String(contentsOf: file.deletingPathExtension().appendingPathExtension("md"), encoding: .utf8) else { return nil }
        let stem = file.deletingPathExtension().lastPathComponent
        let title = md.components(separatedBy: "\n").first { $0.hasPrefix("# ") }
            .map { $0.dropFirst(2).trimmingCharacters(in: .whitespaces) } ?? ""
        return (stem, String((title.isEmpty ? "Meeting" : title).prefix(200)), String(NoteName.stamp(stem).prefix(10)), CloudSync.meetingShareBody(md))
    }

    /// `project` nil: {paired, projects, body, suggested, why, sent}: body is exactly what Push sends,
    /// suggested the project Nikxel thinks it's from, sent where it last went. Otherwise sends to that
    /// project. Answers through `later`, off the listener queue (both can block 20s).
    static func handle(project: String?, file: URL, later: @escaping ([String: Any]) -> Void) {
        guard let m = meeting(file) else { return later(["error": "Only saved meeting minutes can be shared to a project."]) }
        let sentURL = file.deletingPathExtension().appendingPathExtension("shared.json")
        DispatchQueue.global().async {
            guard let project = project else {
                let paired = CloudSync.token != nil, projects = CloudSync.projects()
                let sent = (try? Data(contentsOf: sentURL)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                let pick = suggest(projects, title: m.title, body: m.body, picks: Picks.load())
                return later(["paired": paired, "projects": projects.map { ["id": $0.id, "name": $0.name] }, "body": m.body,
                              "suggested": (sent?["project"] as? String) ?? pick?.id ?? NSNull(), "why": sent == nil ? pick?.why ?? "" : "",
                              "sent": sent ?? NSNull()])
            }
            guard CloudSync.token != nil else { return later(["error": "Connect Nikxel to the dashboard first"]) }
            guard !project.isEmpty else { return later(["error": "Pick a project."]) }
            let ok = CloudSync.shareMeeting(projectID: project, meetingID: m.id, title: m.title, date: m.date, body: m.body)
            cblog("ProjectShare: \(m.id) → \(project): \(ok ? "sent" : "failed")")
            guard ok else { return later(["error": "Couldn't push it. Check you're still on that project, then try again."]) }
            // Where it went (this page shows it), and what to suggest next time.
            let name = CloudSync.projects().first { $0.id == project }?.name ?? ""
            let sent: [String: Any] = ["project": project, "name": name, "at": Date().timeIntervalSince1970]
            if let d = try? JSONSerialization.data(withJSONObject: sent) { try? d.write(to: sentURL, options: .atomic) }
            var picks = Picks.load(); picks.last = project; picks.titles[seriesKey(m.title)] = project; picks.save()
            later(["ok": true, "sent": sent])
        }
    }

    // MARK: - Which project a meeting is from

    /// What the user picked before: the last project, and one per meeting title (a weekly call goes
    /// where it went last week). ~/.nikxel/project-picks.json.
    struct Picks: Codable {
        var last: String?
        var titles: [String: String] = [:]
        static var file = URL(fileURLWithPath: NSHomeDirectory() + "/.nikxel/project-picks.json")
        static func load() -> Picks { (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(Picks.self, from: $0) } ?? Picks() }
        func save() { try? JSONEncoder().encode(self).write(to: Self.file, options: .atomic) }
    }

    /// A meeting title without its dates and numbers, so "Weekly sync 12 Nov" and "Weekly sync 19 Nov" match.
    static func seriesKey(_ title: String) -> String {
        title.lowercased().replacingOccurrences(of: #"[^a-z]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\b(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\b"#, with: " ", options: .regularExpression)
            .split(separator: " ").joined(separator: " ")
    }

    /// The project these minutes are most likely about, and why: where a meeting with this title went
    /// before (the user's own pick wins); else the one named most in the title and minutes (the title
    /// counts three times); else the last project used. nil: no idea, the user picks.
    /// ponytail: name matching, not a model; ask the agent if suggestions miss too often.
    static func suggest(_ projects: [CloudSync.Project], title: String, body: String, picks: Picks) -> (id: String, why: String)? {
        let ids = Set(projects.map(\.id))
        if let id = picks.titles[seriesKey(title)], ids.contains(id) { return (id, "Where this meeting went last time.") }
        let text = " " + ([title, title, title, body].joined(separator: " ").lowercased()
            .replacingOccurrences(of: #"[^\p{L}\p{N}]+"#, with: " ", options: .regularExpression)) + " "
        func count(_ w: String) -> Int { text.components(separatedBy: " " + w + " ").count - 1 }
        let common: Set = ["project", "projects", "app", "team", "the", "and", "for", "with", "new", "client", "meeting", "website", "dashboard"]
        let scored = projects.map { p -> (CloudSync.Project, Int) in
            let name = p.name.lowercased().replacingOccurrences(of: #"[^\p{L}\p{N}]+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            let words = name.split(separator: " ").map(String.init).filter { $0.count >= 4 && !common.contains($0) }
            // Each distinctive word it's said, plus a bonus when a two-word-or-longer name is said whole.
            return (p, words.map(count).reduce(0, +) + (name.contains(" ") ? count(name) * 2 : 0))
        }
        if let best = scored.max(by: { $0.1 < $1.1 }), best.1 > 0, scored.filter({ $0.1 == best.1 }).count == 1 {
            return (best.0.id, "It’s named in these minutes.")
        }
        if let id = picks.last, ids.contains(id) { return (id, "The project you used last.") }
        return nil
    }
}
