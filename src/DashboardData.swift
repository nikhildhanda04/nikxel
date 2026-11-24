import Foundation

/// What the Nikxel window's Tasks, People and Activity sections are built from,
/// read straight from the summaries on disk each time (so an edit or a new
/// meeting shows up on the next look). Foundation only;
/// checks/check_dashboard_data.swift covers the parsing.
enum DashboardData {
    struct Item: Equatable { let n: Int; let done: Bool; let text, owner, due: String }

    /// A meeting's "## Action Items", numbered from 1 the way NotePage numbers
    /// its checkboxes (task-1, task-2…), so a tick here can tick the page too.
    static func actionItems(_ md: String) -> [Item] {
        var out: [Item] = [], inside = false
        for raw in md.components(separatedBy: "\n") {
            if raw.hasPrefix("## ") { inside = raw.dropFirst(3).trimmingCharacters(in: .whitespaces).lowercased() == "action items"; continue }
            guard inside, let (done, item) = task(raw), !isNone(item) else { continue }
            let (text, fields) = splitFields(item)
            func field(_ k: String) -> String {
                let v = fields.first { $0.key.lowercased() == k }?.value.trimmingCharacters(in: .whitespaces) ?? ""
                return unset(v) ? "" : v
            }
            out.append(Item(n: out.count + 1, done: done,
                            text: text.replacingOccurrences(of: "**", with: "").trimmingCharacters(in: .whitespaces),
                            owner: field("owner"), due: field("due")))
        }
        return out
    }

    /// The md with action item `n` ticked or unticked; nil if there's no such item.
    static func markItem(_ md: String, n: Int, done: Bool) -> String? {
        var lines = md.components(separatedBy: "\n"), inside = false, seen = 0
        for (k, raw) in lines.enumerated() {
            if raw.hasPrefix("## ") { inside = raw.dropFirst(3).trimmingCharacters(in: .whitespaces).lowercased() == "action items"; continue }
            guard inside, let (_, item) = task(raw), !isNone(item) else { continue }
            seen += 1
            guard seen == n, let r = raw.range(of: #"\[[ xX]\]"#, options: .regularExpression) else { continue }
            lines[k] = raw.replacingCharacters(in: r, with: done ? "[x]" : "[ ]")
            return lines.joined(separator: "\n")
        }
        return nil
    }

    /// "- [ ] item" / "- [x] item".
    private static func task(_ raw: String) -> (Bool, String)? {
        let t = raw.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("- [") || t.hasPrefix("* ["), t.count > 6 else { return nil }
        let box = t.dropFirst(2).prefix(4).lowercased()
        guard box == "[ ] " || box == "[x] " else { return nil }
        return (box == "[x] ", String(t.dropFirst(6)))
    }

    // Same rules as NoteExporter.isNone / splitFields, which can't be built on their own.
    private static func isNone(_ text: String) -> Bool {
        let t = text.lowercased().trimmingCharacters(in: .whitespaces)
        return t == "none" || t == "none." || t.hasPrefix("none —") || t.hasPrefix("none -")
    }

    private static func splitFields(_ item: String) -> (String, [(key: String, value: String)]) {
        var text: [String] = [], out: [(key: String, value: String)] = []
        for (i, part) in item.components(separatedBy: " — ").enumerated() {
            guard i > 0, let colon = part.firstIndex(of: ":") else { text.append(part); continue }
            let key = part[..<colon].trimmingCharacters(in: .whitespaces)
            let value = part[part.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, key.count <= 12, !value.isEmpty, key.allSatisfy({ $0.isLetter || $0 == " " }) else { text.append(part); continue }
            out.append((key, value))
        }
        return (text.joined(separator: " — "), out)
    }

    static func unset(_ v: String) -> Bool {
        let l = v.lowercased()
        return l.isEmpty || l.hasPrefix("not specified") || l.hasPrefix("not stated") || l.hasPrefix("unassigned") || l == "tbd" || l == "none"
    }

    /// "## Attendees" names: "- Ali Rajeh: client" → "Ali Rajeh". The user
    /// ("Me", "Nikhil (Me)") and "Others" are left out.
    static func attendees(_ md: String) -> [String] {
        var out: [String] = [], inside = false
        for raw in md.components(separatedBy: "\n") {
            if raw.hasPrefix("## ") { inside = raw.dropFirst(3).trimmingCharacters(in: .whitespaces).lowercased() == "attendees"; continue }
            guard inside, raw.hasPrefix("- ") || raw.hasPrefix("* ") else { continue }
            var name = String(raw.dropFirst(2))
            if isMe(name.components(separatedBy: ":")[0]) { continue }
            for sep in [":", " — ", " – ", " - ", " ("] { if let r = name.range(of: sep) { name = String(name[..<r.lowerBound]) } }
            if let n = person(name), !out.contains(n) { out.append(n) }
        }
        return out
    }

    /// A name as a person to list: notes like "*(likely)*" or "(not on call)"
    /// dropped; nil for the user, "Others", "Speaker 2", "Nikhil's side", "Unassigned".
    static func person(_ raw: String) -> String? {
        if isMe(raw) { return nil }
        let name = raw.replacingOccurrences(of: #"\*?\([^)]*\)\*?|\*\*|\*"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        let l = name.lowercased()
        guard name.count > 1, !unset(name), !l.hasPrefix("other"), !l.hasPrefix("speaker"), !l.hasPrefix("unknown"),
              !l.contains("'s side"), !l.contains("’s side"), !l.hasPrefix("everyone"), !l.hasPrefix("all ") else { return nil }
        return name
    }

    /// "Nikhil (Me)", "Me", "Me (Nikhil)".
    static func isMe(_ name: String) -> Bool {
        let l = name.lowercased()
        return l == "me" || l.contains("(me)") || l.hasPrefix("me ")
    }

    /// Lines of each summary that contain every word of `query`, for the Library's search.
    static func search(_ query: String, in files: [(id: String, md: URL)], limit: Int = 60) -> [[String: String]] {
        let words = query.lowercased().split(separator: " ").map(String.init).filter { !$0.isEmpty }
        guard !words.isEmpty else { return [] }
        var out: [[String: String]] = []
        for f in files {
            guard let text = try? String(contentsOf: f.md, encoding: .utf8) else { continue }
            let lower = text.lowercased()
            guard words.allSatisfy(lower.contains) else { continue }
            let line = text.components(separatedBy: "\n").first { l in words.contains { l.lowercased().contains($0) } } ?? ""
            let clean = line.replacingOccurrences(of: #"^[#\-*>\s\[\]xX]+|\*\*|`"#, with: "", options: .regularExpression)
            out.append(["id": f.id, "match": String(clean.trimmingCharacters(in: .whitespaces).prefix(180))])
            if out.count == limit { break }
        }
        return out
    }

    /// The WhatsApp replies the bot sent on `day`, newest first, from
    /// WhatsAppActivityLogger's bot-yyyy-MM-dd.jsonl.
    static func botReplies(on day: Date, in dir: URL) -> [[String: Any]] {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        guard let text = try? String(contentsOf: dir.appendingPathComponent("bot-\(f.string(from: day)).jsonl"), encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { line in
            guard let o = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let t = o["t"] as? Double, let name = o["name"] as? String else { return nil }
            return ["t": t, "name": name, "text": o["text"] as? String ?? ""]
        }.reversed()
    }

    /// Every action item in the meetings and notes, and the people in them.
    /// `me`: the user's own names, so "Nikhil" in an attendee list isn't a person to list.
    static func tasksAndPeople(_ library: [SummaryLibrary.Entry], me: [String] = []) -> (tasks: [[String: Any]], people: [[String: Any]]) {
        let me = Set(me.map { $0.lowercased() }.filter { !$0.isEmpty })
        var tasks: [[String: Any]] = []
        struct Person { var meetings: [[String: Any]] = []; var theirs: [[String: Any]] = []; var mine: [[String: Any]] = [] }
        var people: [String: Person] = [:], order: [String] = []
        for e in library where e.kind == "meetings" || e.kind == "notes" {
            let md = e.file.deletingPathExtension().appendingPathExtension("md")
            guard let text = try? String(contentsOf: md, encoding: .utf8) else { continue }
            let meeting: [String: Any] = ["id": e.file.path, "title": e.title, "date": e.date]
            let items = actionItems(text).map { i -> [String: Any] in
                ["md": md.path, "n": i.n, "text": i.text, "owner": i.owner, "due": i.due, "done": i.done,
                 "mine": isMe(i.owner), "meeting": meeting]
            }
            tasks += items
            let owners = items.compactMap { $0["mine"] as? Bool == false ? ($0["owner"] as? String).flatMap(person) : nil }
            var names = attendees(text)
            for o in owners where !names.contains(where: { $0.caseInsensitiveCompare(o) == .orderedSame }) { names.append(o) }
            for name in names where !me.contains(name.lowercased()) {
                let key = name.lowercased()
                if people[key] == nil { order.append(key); people[key] = Person() }
                people[key]?.meetings.append(meeting.merging(["name": name]) { a, _ in a })
                for i in items where i["done"] as? Bool == false {
                    if (i["owner"] as? String).flatMap(person)?.lowercased() == key { people[key]?.theirs.append(i) }
                    else if i["mine"] as? Bool == true { people[key]?.mine.append(i) }
                }
            }
        }
        let list = order.compactMap { key -> [String: Any]? in
            guard let p = people[key], let first = p.meetings.first else { return nil }
            return ["name": first["name"] ?? key, "meetings": p.meetings, "theirs": p.theirs, "mine": p.mine, "last": first["date"] ?? ""]
        }
        return (tasks, list)
    }
}
