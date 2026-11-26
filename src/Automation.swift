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
    /// A temporary one ("remind me tomorrow…"): "yyyy-MM-dd". It runs once, that day at `time` (or as soon
    /// as Nikxel is next awake after it), then switches itself off. nil: it repeats on `days`.
    var date: String?
    /// Files it follows every run (Attachments ids), e.g. the user's SOP format. nil: none.
    var files: [String]?

    static let triggers = ["meeting", "day", "week", "schedule"]
    static let weekdays = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"]

    /// "After every meeting", "Weekdays at 09:00"…
    var when: String {
        if let date, trigger == "schedule" {
            let f = Self.dayFormatter, out = DateFormatter()
            out.dateFormat = "EEE d MMM"
            let d = f.date(from: date)
            let cal = Calendar.current
            let day = d.map { cal.isDateInToday($0) ? "today" : cal.isDateInTomorrow($0) ? "tomorrow" : out.string(from: $0) } ?? date
            return "Once, \(day) at \(time)"
        }
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
        if let date {
            // Late is fine (the Mac was asleep at 9): it still runs, once.
            let f = Self.dayFormatter; f.calendar = calendar; f.timeZone = calendar.timeZone
            guard lastRun.isEmpty, let day = f.date(from: date) else { return false }
            let hm = time.split(separator: ":").compactMap { Int($0) }
            return hm.count == 2 && calendar.date(bySettingHour: hm[0], minute: hm[1], second: 0, of: day).map { now >= $0 } == true
        }
        let c = calendar.dateComponents([.hour, .minute, .weekday], from: now)
        guard String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0) == time else { return false }
        let wd = Self.weekdays[((c.weekday ?? 1) - 1) % 7]
        let dayOK = days == "daily" || (days == "weekdays" && !["sat", "sun"].contains(wd)) || days == wd
        return dayOK && lastRun != Self.minuteKey(now)
    }

    static var dayFormatter: DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
        return f
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
        if a.trigger != "schedule" || a.date.flatMap(dayFormatter.date(from:)) == nil { a.date = nil }
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

    static let shape = #"{"name": "short name", "trigger": "meeting|day|week|schedule", "time": "HH:mm", "days": "daily|weekdays|mon|tue|wed|thu|fri|sat|sun", "date": "yyyy-MM-dd, only for a one-time one (a reminder or a task for a given day); leave it out for a repeating one", "instruction": "what Nikxel should do, written to Nikxel, ending with: If there's nothing to do, reply SKIP."}"#

    static let can = """
    What an automation can do when it runs (it is carried out by Nikxel's chat, which can see the user's \
    meeting minutes, day and week summaries and notes from the last 14 days, their team projects, WhatsApp \
    chats when WhatsApp is open, their Gmail inbox when Google is connected, and their ERP when connected): \
    answer or summarise something and show it to the user; read the open tasks in ERP (who they're for, \
    stage, deadline); draft an email in Gmail (never send it); make a task in ERP. It cannot send WhatsApp messages or emails by itself.
    Triggers: "meeting" runs after every meeting summary (the summary is given to it), "day" after the \
    end-of-day summary, "week" after the weekly summary, "schedule" at a time on given days, or once on a "date" \
    (then it switches itself off). It can be given files the user attached (a template or format to \
    follow, a price list), which it gets every time it runs. An automation can be for only some \
    meetings (client calls, ones where an SOP is needed): it decides from each meeting's summary.
    """

    /// Turn the user's request into one automation.
    static func makePrompt(request: String, now: Date = Date(), files: [String] = []) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "EEEE yyyy-MM-dd HH:mm"
        return """
        The user wants Nikxel to set up an automation. \(can)
        It's \(f.string(from: now)) now. Something for one day ("remind me tomorrow morning to…", "on Friday \
        check…", "at 5 to…") is a one-time "schedule" with a "date"; "every…", "each…" or "after meetings" repeats. \
        Morning is 09:00, afternoon 14:00, evening 18:00, unless they say a time. For a reminder the \
        instruction is "Remind me to <what they said>, in one or two short lines, adding anything useful you \
        can see about it." and never ends with SKIP. Name it after the task, e.g. "Remind: call Vikas". \
        If they want it only for some meetings or days (e.g. "only client calls", "when an SOP is needed"), \
        start the instruction with that test spelled out, e.g. "If this was a call with a client or someone \
        outside my company where a process was agreed, …; otherwise reply SKIP."\(files.isEmpty ? "" : " The user attached \(files.map { "“\($0)”" }.joined(separator: ", ")) for it; it gets the file every run, so the instruction says to follow it by name, e.g. \"write an SOP in the exact format of “\(files[0])”\".")

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
                               instruction: d["instruction"] as? String ?? "", date: d["date"] as? String,
                               files: (d["files"] as? [String]).flatMap { $0.isEmpty ? nil : $0 })
            return clean(a).map { ($0, d["why"] as? String ?? "") }
        }
    }

    /// "Remind me…", "set a reminder…": the chat makes an automation for it instead of only saying it will.
    static func looksLikeReminder(_ text: String) -> Bool {
        text.range(of: #"\b(remind me|(set|add|make|create) (me )?(an? )?reminder|nudge me|ping me|don'?t let me forget|(set up|add|make|create) (an? )?automation)\b"#,
                   options: [.regularExpression, .caseInsensitive]) != nil
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
        ["id": id, "name": name, "trigger": trigger, "time": time, "days": days, "instruction": instruction, "enabled": enabled, "when": when,
         "date": date ?? NSNull(), "done": date != nil && !lastRun.isEmpty,
         "files": files ?? []]
    }
}
