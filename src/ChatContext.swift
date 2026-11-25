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
    /// (daily, meeting, note within a day). Files not dated by NoteName.stamp, or that don't end .md, are skipped.
    static func localBlocks(root: URL, today: Date, days: Int = 14) -> [Block] {
        let end = dayString(today)
        let start = dayString(Calendar.current.date(byAdding: .day, value: -(days - 1), to: today) ?? today)
        let dateRe = try! NSRegularExpression(pattern: #"^\d{4}-\d{2}-\d{2}$"#)
        var out: [Block] = []
        for kind in ["daily", "meeting", "note"] {
            let dir = root.appendingPathComponent(kind == "meeting" ? "meetings" : kind == "note" ? "notes" : "daily")
            for f in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [] where f.hasSuffix(".md") {
                let date = String(NoteName.stamp(String(f.dropLast(3))).prefix(10))  // "<name> <stamp>" once named
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
        // Each block's length once and a running total (plus "\n\n" between blocks): joining per drop was quadratic.
        var lens = bs.map { render($0).count }
        var total = lens.reduce(0, +) + 2 * max(bs.count - 1, 0)
        while total > cap && bs.count > 1 {
            let i = bs.lastIndex { $0.kind == "daily" && $0.date < cutoff } ?? bs.count - 1
            total -= lens[i] + 2
            bs.remove(at: i); lens.remove(at: i)
        }
        return String(joined().prefix(cap))
    }

    enum Click { case chat, none }

    /// A press-and-release on the avatar: under 4 pt of travel with no second click opens (or closes) the chat.
    /// 4 pt or more was a drag; a second click is the recording double-click.
    static func clickDecision(moved: Double, secondClick: Bool) -> Click {
        moved < 4 && !secondClick ? .chat : .none
    }

    /// How to use Nikxel, for "how do I record a meeting?" or "where are my day summaries?". The Nikxel
    /// window comes first; folders only as a second way. Mirrors windows/src/main/system/chatContext.ts.
    static let appHelp = """
        - Open the Nikxel window: click the Nikxel icon in the menu bar, then Open Nikxel… (or press ⌘ ,). Everything below is in its sidebar.
        - Record a meeting: double-click me (the avatar) to start, double-click again to stop. Or the Record button in the Nikxel window, or the menu bar icon. When it stops I write the meeting summary.
        - Chat with me: click me once on your screen, or Chat in the Nikxel window.
        - Meeting summaries: Library → Meetings in the Nikxel window. Open one to read, share, edit or rename it there.
        - Daily summaries: Library → Days; weekly ones: Library → Weeks. The time your day is written up: Recording & notes.
        - Notes (not meetings): Library → Notes. Switch between Meeting and Notes recording in Recording & notes.
        - Action items from meetings: Tasks. People you've met with: People.
        - Things to do every time (after a meeting, each morning): Automations. My suggestions about how you work, including any you missed on screen: Automations → What I've suggested.
        - WhatsApp replies and settings: WhatsApp. Google, Gmail, ERP and Slack: Connections. Your name, avatar and what I know about you: You.
        - What I did on WhatsApp today and AI cost: Activity. Folders, logs, updates, setup again and the tour again: Advanced.
        - Move me: drag me anywhere. Hide or show me, mute, record: the menu bar icon.
        - The files themselves, only if they ask for the folder: ~/Documents/nikxel (meetings, daily, weekly, notes), settings in ~/.nikxel. Advanced in the Nikxel window opens them.
        """

    static func prompt(context: String, history: [(q: String, a: String)], question: String, today: Date) -> String {
        var p = """
        You are the user's desk avatar. Today is \(dayString(today)). Answer using only the notes below. \
        If the answer isn't in them, say so plainly; never guess. Reply in a few short lines or bullets, \
        and name the meeting, person or date you got it from.

        If the question is about Nikxel itself (how to do something, where something is), answer from HOW NIKXEL WORKS: \
        point to the place in the Nikxel window first, and give a folder only as a second way or if they ask for files. \
        End every answer about Nikxel with one short line saying that what Nikxel records and saves stays on this computer.

        HOW NIKXEL WORKS:
        \(appHelp)

        NOTES:
        \(context)

        """
        for h in history { p += "\nUser: \(h.q)\nYou: \(h.a)\n" }
        return p + "\nUser: \(question)"
    }
}
