import Foundation

/// A user's automation: when something happens (a meeting summary, the day or
/// week summary, or a time), Nikxel carries out a plain-English instruction
/// through the chat (ChatSession), which can answer, draft an email or make an
/// ERP task, and never sends mail by itself. Kept in ~/.nikxel/automations.json.
/// Automations.swift runs them; this file is Foundation only, so
/// checks/check_automation.swift can cover the rules.
struct Automation: Codable, Equatable {
    var id: String
    var name: String
    /// "meeting", "day", "week" or "schedule".
    var trigger: String
    /// For "schedule": "HH:mm", and "daily", "weekdays" or "mon"…"sun".
    var time: String = "09:00"
    var days: String = "daily"
    var instruction: String
    var enabled: Bool = true
    /// "yyyy-MM-dd HH:mm" of the last scheduled run, so a minute is never run twice.
    var lastRun: String = ""

    static let triggers = ["meeting", "day", "week", "schedule"]
    static let weekdays = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"]

    /// "After every meeting", "Weekdays at 09:00"…
    var when: String {
        switch trigger {
        case "meeting": return "After every meeting summary"
        case "day": return "After your day summary"
        case "week": return "After your week summary"
        default:
            let d = days == "daily" ? "Every day" : days == "weekdays" ? "Weekdays"
                : "Every " + (["sun": "Sunday", "mon": "Monday", "tue": "Tuesday", "wed": "Wednesday", "thu": "Thursday", "fri": "Friday", "sat": "Saturday"][days] ?? days)
            return "\(d) at \(time)"
        }
    }

    /// Due at `now` (a schedule whose minute it is, not already run this minute).
    func due(at now: Date, calendar: Calendar = .current) -> Bool {
        guard enabled, trigger == "schedule" else { return false }
        let c = calendar.dateComponents([.hour, .minute, .weekday], from: now)
        guard String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0) == time else { return false }
        let wd = Self.weekdays[((c.weekday ?? 1) - 1) % 7]
        let dayOK = days == "daily" || (days == "weekdays" && !["sat", "sun"].contains(wd)) || days == wd
        return dayOK && lastRun != Self.minuteKey(now)
    }

    static func minuteKey(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: d)
    }

    /// Anything the agent or the page sends, made valid: a known trigger, a real
    /// HH:mm, a known day set, a name. nil when there's no instruction.
    static func clean(_ a: Automation) -> Automation? {
        var a = a
        a.instruction = a.instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !a.instruction.isEmpty else { return nil }
        a.name = a.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if a.name.isEmpty { a.name = String(a.instruction.prefix(48)) }
        if !triggers.contains(a.trigger) { a.trigger = "schedule" }
        let hm = a.time.split(separator: ":").compactMap { Int($0) }
        a.time = hm.count == 2 && (0..<24).contains(hm[0]) && (0..<60).contains(hm[1]) ? String(format: "%02d:%02d", hm[0], hm[1]) : "09:00"
        if !(["daily", "weekdays"] + weekdays).contains(a.days) { a.days = "daily" }
        if a.id.isEmpty { a.id = UUID().uuidString }
        return a
    }

    // MARK: - Ideas

    /// Ready-made ones, shown before Nikxel has suggested any of its own.
    static let ideas: [Automation] = [
        Automation(id: "", name: "Follow-up email after client calls", trigger: "meeting",
                   instruction: "If this was a call with a client or someone outside my company, draft a short follow-up email to them with what we agreed and the next steps, with owners and dates. If it was internal, reply SKIP."),
        Automation(id: "", name: "My tasks from every meeting", trigger: "meeting",
                   instruction: "List only the action items I own from this meeting, with their due dates, as a short checklist. If I own none, reply SKIP."),
        Automation(id: "", name: "Morning brief", trigger: "schedule", time: "09:00", days: "weekdays",
                   instruction: "Give me a short brief for today: my open tasks, anything I promised someone that is due soon, and who is waiting on me on WhatsApp or email."),
        Automation(id: "", name: "Friday wrap-up", trigger: "schedule", time: "17:00", days: "fri",
                   instruction: "Summarise my week in five bullets: what got done, what's still open, and what I should start Monday with."),
        Automation(id: "", name: "Blocked work alert", trigger: "day",
                   instruction: "From today's summary, list anything that is blocked and who it is waiting on, with a one-line nudge I could send them. If nothing is blocked, reply SKIP."),
        Automation(id: "", name: "Make ERP tasks from my meetings", trigger: "meeting",
                   instruction: "Make a task in ERP for the most important action item I own from this meeting, with its due date. If I own none, reply SKIP."),
        Automation(id: "", name: "Unanswered messages at lunch", trigger: "schedule", time: "13:00", days: "weekdays",
                   instruction: "Who has been waiting on a reply from me on WhatsApp or email since this morning? List them with what they asked, most urgent first. If no one, reply SKIP."),
        Automation(id: "", name: "Weekly people check-in", trigger: "week",
                   instruction: "From this week, list the people I owe something to and what it is, so I can clear it before Monday."),
    ]

    // MARK: - Asking the agent

    static let shape = #"{"name": "short name", "trigger": "meeting|day|week|schedule", "time": "HH:mm", "days": "daily|weekdays|mon|tue|wed|thu|fri|sat|sun", "instruction": "what Nikxel should do, written to Nikxel, ending with: If there's nothing to do, reply SKIP."}"#

    static let can = """
    What an automation can do when it runs (it is carried out by Nikxel's chat, which can see the user's \
    meeting minutes, day and week summaries and notes from the last 14 days, their team projects, WhatsApp \
    chats when WhatsApp is open, their Gmail inbox when Google is connected, and Forklyft ERP when connected): \
    answer or summarise something and show it to the user; draft an email in Gmail (never send it); make a \
    task in ERP. It cannot send WhatsApp messages or emails by itself.
    Triggers: "meeting" runs after every meeting summary (the summary is given to it), "day" after the \
    end-of-day summary, "week" after the weekly summary, "schedule" at a time on given days.
    """

    /// Turn the user's request into one automation.
    static func makePrompt(request: String) -> String {
        """
        The user wants Nikxel to set up an automation. \(can)

        Reply with only one JSON object, no prose, in this shape:
        \(shape)

        The user's request: \(request)
        """
    }

    /// Suggest automations from what the user's recent work looks like.
    static func suggestPrompt(context: String, existing: [Automation]) -> String {
        """
        Suggest 4 automations that would genuinely save this user time, based on their recent work below. \
        Make them specific to the people, clients, projects and routines you can see, not generic. \
        Don't repeat any they already have. \(can)

        Reply with only a JSON array of objects, no prose, each in this shape plus a "why" field \
        (one sentence on what you saw that made you suggest it):
        \(shape)

        Automations they already have: \(existing.map(\.name).joined(separator: "; ").isEmpty ? "none" : existing.map(\.name).joined(separator: "; "))

        Their recent work:
        \(context.prefix(40_000))
        """
    }

    /// The first JSON object or array in an agent's reply, as automations
    /// (with "why" when the agent gave one). Invalid ones are dropped.
    static func parse(_ reply: String) -> [(Automation, why: String)] {
        let open = reply.firstIndex(where: { $0 == "{" || $0 == "[" })
        let close = reply.lastIndex(where: { $0 == "}" || $0 == "]" })
        guard let o = open, let c = close, o < c,
              let any = try? JSONSerialization.jsonObject(with: Data(reply[o...c].utf8)) else { return [] }
        let list = (any as? [[String: Any]]) ?? [(any as? [String: Any])].compactMap { $0 }
        return list.compactMap { d in
            let a = Automation(id: "", name: d["name"] as? String ?? "", trigger: d["trigger"] as? String ?? "",
                               time: d["time"] as? String ?? "09:00", days: (d["days"] as? String ?? "daily").lowercased(),
                               instruction: d["instruction"] as? String ?? "")
            return clean(a).map { ($0, d["why"] as? String ?? "") }
        }
    }

    // MARK: - Store

    static var file = URL(fileURLWithPath: NSHomeDirectory() + "/.nikxel/automations.json")

    static func load() -> [Automation] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        return (try? JSONDecoder().decode([Automation].self, from: data)) ?? []
    }

    static func save(_ list: [Automation]) {
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? enc.encode(list).write(to: file, options: .atomic)
    }

    var dict: [String: Any] {
        ["id": id, "name": name, "trigger": trigger, "time": time, "days": days, "instruction": instruction, "enabled": enabled, "when": when]
    }
}
