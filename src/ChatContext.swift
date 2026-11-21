import Foundation

/// Builds the text the avatar chat answers from: the last 14 days of daily summaries, meeting minutes and notes
/// under ~/Documents/nikxel, plus the dashboard project feed. Foundation only. Mirrors chatContext.ts.
enum ChatContext {
    /// Characters of context sent to the agent (measured in Task 2: see report).
    static let cap = 250_000

    struct Block: Equatable { let kind, date, name, text: String }

    private static func dayString(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }

    /// Daily summaries, meeting minutes and notes dated within `days` days up to today, newest first
    /// (daily, meeting, note within a day). Files whose first 10 characters aren't a date, or that don't end .md, are skipped.
    static func localBlocks(root: URL, today: Date, days: Int = 14) -> [Block] {
        let end = dayString(today)
        let start = dayString(Calendar.current.date(byAdding: .day, value: -(days - 1), to: today) ?? today)
        let dateRe = try! NSRegularExpression(pattern: #"^\d{4}-\d{2}-\d{2}$"#)
        var out: [Block] = []
        for kind in ["daily", "meeting", "note"] {
            let dir = root.appendingPathComponent(kind == "meeting" ? "meetings" : kind == "note" ? "notes" : "daily")
            for f in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [] where f.hasSuffix(".md") {
                let date = String(f.prefix(10))
                guard dateRe.firstMatch(in: date, range: NSRange(date.startIndex..., in: date)) != nil,
                      date >= start, date <= end,
                      let text = try? String(contentsOf: dir.appendingPathComponent(f), encoding: .utf8) else { continue }
                out.append(Block(kind: kind, date: date, name: String(f.dropLast(3)), text: text.trimmingCharacters(in: .whitespacesAndNewlines)))
            }
        }
        let order = ["daily": 0, "meeting": 1, "note": 2, "project": 3]
        return out.sorted { ($0.date, order[$1.kind]!, $1.name) > ($1.date, order[$0.kind]!, $0.name) }
    }

    /// One block per project per day from the device project feed.
    static func projectBlocks(_ feed: [[String: Any]]) -> [Block] {
        var out: [Block] = []
        for p in feed {
            guard let name = p["name"] as? String else { continue }
            for d in p["days"] as? [[String: Any]] ?? [] {
                guard let date = d["date"] as? String else { continue }
                var lines: [String] = []
                for m in d["meetings"] as? [[String: Any]] ?? [] {
                    lines.append("Meeting: \(m["title"] as? String ?? "")" + ((m["name"] as? String).map { " (\($0))" } ?? "") + "\n" + (m["body"] as? String ?? ""))
                }
                for i in d["items"] as? [[String: Any]] ?? [] {
                    lines.append("- " + (i["what"] as? String ?? "") + ((i["name"] as? String).map { " (\($0))" } ?? ""))
                }
                if !lines.isEmpty { out.append(Block(kind: "project", date: date, name: name, text: lines.joined(separator: "\n"))) }
            }
        }
        return out
    }

    /// Blocks newest first as "### kind · date · name" sections, at most `cap` characters. Over the cap,
    /// daily summaries older than 2 days go first, then the oldest of anything; a lone block is cut to fit.
    static func build(_ blocks: [Block], cap: Int) -> String {
        var bs = blocks.enumerated().sorted { ($0.element.date, $1.offset) > ($1.element.date, $0.offset) }.map(\.element) // stable
        func render(_ b: Block) -> String { "### \(b.kind) · \(b.date) · \(b.name)\n\(b.text)" }
        func joined() -> String { bs.map(render).joined(separator: "\n\n") }
        let cutoff = dayString(Calendar.current.date(byAdding: .day, value: -2, to: Date()) ?? Date())
        var s = joined()
        while s.count > cap && bs.count > 1 {
            let i = bs.lastIndex { $0.kind == "daily" && $0.date < cutoff } ?? bs.count - 1
            bs.remove(at: i)
            s = joined()
        }
        return String(s.prefix(cap))
    }

    enum Click { case chat, none }

    /// A press-and-release on the avatar: under 4 pt of travel with no second click opens (or closes) the chat.
    /// 4 pt or more was a drag; a second click is the recording double-click.
    static func clickDecision(moved: Double, secondClick: Bool) -> Click {
        moved < 4 && !secondClick ? .chat : .none
    }

    static func prompt(context: String, history: [(q: String, a: String)], question: String, today: Date) -> String {
        var p = """
        You are the user's desk avatar. Today is \(dayString(today)). Answer using only the notes below. \
        If the answer isn't in them, say so plainly; never guess. Reply in a few short lines or bullets, \
        and name the meeting, person or date you got it from.

        NOTES:
        \(context)

        """
        for h in history { p += "\nUser: \(h.q)\nYou: \(h.a)\n" }
        return p + "\nUser: \(question)"
    }
}
