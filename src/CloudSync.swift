import Foundation
import CryptoKit

/// Pairs this Mac with the org dashboard and pushes the derived work summary.
/// DATA BOUNDARY: the only things that ever leave are {kind, date, headline, items:[{id,section,what,type,minutes,details,project}]}, sent on the user's Send click
/// (items include ERP task names, stages, deadlines and project names), and a meeting's minutes minus its Client Summary, sent on Share to project
/// (never the transcript or audio), plus the device token as bearer. Never logs, twin, erp.md, raw activity or email.
/// Mirrors cloudSync.ts.
enum CloudSync {
    /// Dev default; set NIKXEL_BACKEND to point elsewhere. No production URL yet.
    static var backendBase: String { ProcessInfo.processInfo.environment["NIKXEL_BACKEND"] ?? "http://localhost:3001" }
    private static var tokenFile: String { NSHomeDirectory() + "/.nikxel/cloud-token" }

    static var token: String? {
        let t = (try? String(contentsOfFile: tokenFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (t?.isEmpty ?? true) ? nil : t
    }

    /// Blocking POST (callers are off the main thread). Returns the 2xx body, nil on any failure.
    typealias Poster = (_ path: String, _ body: [String: Any], _ bearer: String?) -> Data?
    /// Blocking POST: the HTTP status and body, nil when the server can't be reached.
    typealias StatusPoster = (_ path: String, _ body: [String: Any], _ bearer: String?) -> (status: Int, data: Data?)?

    static let httpSend: StatusPoster = { path, body, bearer in
        guard let url = URL(string: backendBase + path),
              let data = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let b = bearer { req.setValue("Bearer \(b)", forHTTPHeaderField: "Authorization") }
        req.httpBody = data
        var out: (status: Int, data: Data?)?
        let sem = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: req) { d, r, _ in
            if let h = r as? HTTPURLResponse { out = (h.statusCode, d) }
            sem.signal()
        }.resume()
        sem.wait()
        return out
    }

    static let httpPost: Poster = { path, body, bearer in
        httpSend(path, body, bearer).flatMap { (200..<300).contains($0.status) ? $0.data : nil }
    }

    static func pair(_ code: String, post: Poster = httpPost) -> Bool {
        let c = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !c.isEmpty, let data = post("/api/pair", ["code": c], nil),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tok = obj["deviceToken"] as? String, !tok.isEmpty else { return false }
        try? FileManager.default.createDirectory(atPath: (tokenFile as NSString).deletingLastPathComponent,
                                                 withIntermediateDirectories: true)
        guard FileManager.default.createFile(atPath: tokenFile, contents: Data(tok.utf8),
                                             attributes: [.posixPermissions: 0o600]) else { return false }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tokenFile)
        try? FileManager.default.removeItem(atPath: projectsFile) // the last user's project names
        return true
    }

    /// The sections that are sent (work and meetings; never chats or open tasks),
    /// and the type an untagged bullet in each gets.
    static let sectionTypes = ["what you worked on": "other", "meetings": "meeting", "browsing & reading": "research", "erp tasks": "planning"]
    static let types: Set<String> = ["coding", "shipped", "meeting", "research", "learning", "writing", "review", "planning", "comms", "other"]

    /// First 12 hex of SHA-256(section + "\n" + what.lowercased()). The daily page uses it for data-id.
    /// A trailing "— open/done/unclear" is left out, so ticking a task doesn't change its id.
    static func itemID(section: String, what: String) -> String {
        let what = what.replacingOccurrences(of: #"\s+[—–-]\s*\**(done|open|unclear)\**\.?\s*$"#, with: "", options: [.regularExpression, .caseInsensitive])
        return SHA256.hash(data: Data((section + "\n" + what.lowercased()).utf8)).map { String(format: "%02x", $0) }.joined().prefix(12).description
    }

    /// Sends the day (minus `skip` ids; "headline" drops the headline) as kind "day". False on no token, no items (unless allowEmpty: retracts a sent day) or failed POST.
    static func pushDay(summary: String, day: String, skip: Set<String>, allowEmpty: Bool = false, post: Poster = httpPost) -> Bool {
        guard let tok = token else { return false }
        let (headline, all) = dayItems(fromDailySummary: summary)
        let items = all.filter { !skip.contains($0.id) }.map {
            ["id": $0.id, "section": $0.section, "what": $0.what, "type": $0.type, "minutes": $0.minutes, "details": $0.details, "project": $0.project] as [String: Any]
        }
        guard !items.isEmpty || allowEmpty else { return false }
        return post("/api/summaries", ["kind": "day", "date": day, "headline": skip.contains("headline") ? "" : headline, "items": items], tok) != nil
    }

    /// Blocking GET (callers are off the main thread). Returns the 2xx body, nil on any failure.
    typealias Getter = (_ path: String, _ bearer: String?) -> Data?

    static let httpGet: Getter = { path, bearer in
        guard let url = URL(string: backendBase + path) else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 20)
        if let b = bearer { req.setValue("Bearer \(b)", forHTTPHeaderField: "Authorization") }
        var out: Data?
        let sem = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: req) { d, r, _ in
            if let h = r as? HTTPURLResponse, (200..<300).contains(h.statusCode) { out = d }
            sem.signal()
        }.resume()
        sem.wait()
        return out
    }

    struct Project: Equatable { let id, name: String }
    private static var projectsFile: String { NSHomeDirectory() + "/.nikxel/projects.json" }

    /// The user's dashboard projects (for [[Project]] tags and Share to project). The last good list
    /// (~/.nikxel/projects.json) when the dashboard can't be reached; [] when unpaired or never fetched.
    static func projects(get: Getter = httpGet) -> [Project] {
        guard let tok = token else { return [] }
        func parse(_ d: Data?) -> [Project]? {
            (d.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [[String: Any]])?.compactMap { r in
                guard let id = r["id"] as? String, let name = r["name"] as? String else { return nil }
                return Project(id: id, name: name)
            }
        }
        let d = get("/api/device/projects", tok)
        if let fresh = parse(d) {
            try? d?.write(to: URL(fileURLWithPath: projectsFile), options: .atomic)
            return fresh
        }
        return parse(FileManager.default.contents(atPath: projectsFile)) ?? []
    }

    /// The meeting minutes as shared to a project: everything but the "## Client Summary" section
    /// (up to the next "## "), capped at the server's 20000 characters. Never the transcript.
    static func meetingShareBody(_ md: String) -> String {
        var skipping = false
        let kept = md.components(separatedBy: "\n").filter { line in
            if line.hasPrefix("## ") { skipping = line.dropFirst(3).trimmingCharacters(in: .whitespaces).lowercased() == "client summary" }
            return !skipping
        }.joined(separator: "\n")
        guard kept.utf16.count > 20000 else { return kept }
        return String(kept[..<kept.utf16.index(kept.utf16.startIndex, offsetBy: 20000)])
    }

    /// Sends a meeting's minutes to one of the user's projects; re-sharing the same meeting replaces it.
    /// False on no token or failed POST (404 when the user isn't on that project).
    static func shareMeeting(projectID: String, meetingID: String, title: String, date: String, body: String, post: Poster = httpPost) -> Bool {
        guard let tok = token,
              let id = projectID.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~"))) else { return false }
        return post("/api/projects/\(id)/meetings", ["meeting_id": meetingID, "title": title, "date": date, "body": body], tok) != nil
    }

    struct DayItem: Equatable { let id, section, what, type: String; let minutes: Int; let details: [String]; var project = "" }

    /// Top-level bullets of every "## " section but Summary; indented bullets become details.
    /// Minutes from "1h 30m" / "45 min" / "2h" (0 if none). Headline = first paragraph of Summary.
    static func dayItems(fromDailySummary md: String) -> (headline: String, items: [DayItem]) {
        let body = #"(?:(\d+)\s*h(?:ours?|rs?)?(?:\s*(\d+)\s*m(?:in(?:ute)?s?)?)?|(\d+)\s*m(?:in(?:ute)?s?)?)"#
        let dur = try! NSRegularExpression(pattern: #"\b"# + body + #"\b"#, options: .caseInsensitive)
        // A trailing "(~45m)" estimate (optionally before a " — Done" tail or a final ".") beats any duration mentioned earlier in the text.
        let est = try! NSRegularExpression(pattern: #"\(\s*~?\s*"# + body + #"\s*\)(?=\s*(?:[—–-].*)?\.?\s*$)"#, options: .caseInsensitive)
        var section = "", headline = "", headlineDone = false
        var out: [DayItem] = []
        var open = false // last top-level bullet was kept, so indented bullets attach to it
        for line in md.components(separatedBy: "\n") {
            if line.hasPrefix("## ") { section = line.dropFirst(3).lowercased().trimmingCharacters(in: .whitespaces); open = false; continue }
            if section == "summary" {
                let t = line.trimmingCharacters(in: .whitespaces)
                if t.isEmpty { if !headline.isEmpty { headlineDone = true } } else if !headlineDone { headline += (headline.isEmpty ? "" : " ") + t }
                continue
            }
            guard let base = sectionTypes[section] else { continue }
            if line.hasPrefix("- ") || line.hasPrefix("* ") {
                open = false
                var text = String(line.dropFirst(2)).replacingOccurrences(of: "**", with: "")
                var type = base
                // Any [word] tag is hidden on the daily page, so strip it here; unknown ones keep the default type.
                if let r = text.range(of: #"^\[[a-z]+\]\s*"#, options: .regularExpression) {
                    let tag = String(text[r]).trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
                    if types.contains(tag) { type = tag }
                    text.removeSubrange(r)
                }
                // Then an optional [[ERP project]] tag.
                var project = ""
                if let r = text.range(of: #"^\[\[([^\]]+?)\]\]\s*"#, options: .regularExpression) {
                    project = String(text[r].dropFirst(2).prefix(while: { $0 != "]" })).trimmingCharacters(in: .whitespaces)
                    text.removeSubrange(r)
                }
                var minutes = 0
                let ns = text as NSString
                let all = NSRange(location: 0, length: ns.length)
                if section != "erp tasks", let m = est.firstMatch(in: text, range: all) ?? dur.firstMatch(in: text, range: all) {
                    func g(_ i: Int) -> Int { m.range(at: i).location == NSNotFound ? 0 : Int(ns.substring(with: m.range(at: i))) ?? 0 }
                    minutes = g(1) * 60 + g(2) + g(3)
                    text = ns.replacingCharacters(in: m.range, with: "")
                }
                let what = text.replacingOccurrences(of: "~", with: "").replacingOccurrences(of: "()", with: "")
                    .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                    .replacingOccurrences(of: #" \.$"#, with: ".", options: .regularExpression)
                    .trimmingCharacters(in: CharacterSet(charactersIn: " —-–:,;"))
                let low = what.lowercased()
                if what.count < 3 || isNone(low) || low.hasPrefix("none today") || low.hasPrefix("nothing") || low.hasPrefix("no calls") || low.hasPrefix("no tasks") { continue }
                out.append(DayItem(id: itemID(section: section, what: what), section: section, what: what, type: type, minutes: minutes, details: [], project: project))
                open = true
            } else if open, line.hasPrefix(" ") || line.hasPrefix("\t") {
                var d = line.trimmingCharacters(in: .whitespaces)
                guard d.hasPrefix("- ") || d.hasPrefix("* ") else { continue }
                d = String(d.dropFirst(2)).replacingOccurrences(of: "**", with: "")
                let last = out.removeLast()
                out.append(DayItem(id: last.id, section: last.section, what: last.what, type: last.type, minutes: last.minutes, details: last.details + [d], project: last.project))
            }
        }
        return (headline, out)
    }

    /// Same rule as NoteExporter.isNone (kept local so this file stands alone).
    private static func isNone(_ low: String) -> Bool {
        low == "none" || low == "none." || low.hasPrefix("none —") || low.hasPrefix("none -")
    }
}
