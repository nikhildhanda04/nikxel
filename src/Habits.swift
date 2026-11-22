import Foundation

/// The pure half of what Nikxel learns from habits and edits: given the logs, what would it
/// suggest? Nothing here changes anything -- Learning.swift asks the user first. Mirrors
/// windows/src/main/system/habits.ts; checked by check_habits.swift.
enum Habits {
    /// When each day ended: the last activity sample of that day, as minutes after the day's
    /// midnight (past 1440 when it ran on after midnight). A day runs 6am to 6am, so 1:30am
    /// belongs to the evening before. Lock-screen samples don't count as activity, and the day
    /// `now` is in hasn't ended yet, so it's left out.
    static func dayEnds(_ samples: [(t: TimeInterval, app: String)], now: Date, calendar: Calendar = .current) -> [Int] {
        let current = calendar.startOfDay(for: now.addingTimeInterval(-6 * 3600))
        var last: [Date: Date] = [:]
        for s in samples where !["loginwindow", "ScreenSaverEngine"].contains(s.app) {
            let at = Date(timeIntervalSince1970: s.t)
            let day = calendar.startOfDay(for: at.addingTimeInterval(-6 * 3600))
            if last[day].map({ at > $0 }) ?? true { last[day] = at }
        }
        last[current] = nil
        return last.map { Int($0.value.timeIntervalSince($0.key) / 60) }
    }

    /// The summary time to suggest, in minutes after the day's midnight (1440+ = the early hours
    /// after it): 30 minutes past the usual wrap-up, rounded up to the half hour. nil when there
    /// are fewer than 7 days to go on, or the user usually stops before 10:30pm, or the
    /// suggestion is within an hour of `current`.
    static func summaryTime(dayEnds: [Int], current: Int) -> Int? {
        guard dayEnds.count >= 7 else { return nil }
        let sorted = dayEnds.sorted(), median = sorted[sorted.count / 2]
        guard median >= 22 * 60 + 30 else { return nil }
        let suggested = min(((median + 30 + 29) / 30) * 30, 1440 + 5 * 60)  // never past 5am
        return abs(suggested - current) >= 60 ? suggested : nil
    }

    /// "2:30am" for 1590, "11pm" for 1380.
    static func clock(_ minutes: Int) -> String {
        let m = minutes % 1440, h = m / 60, mm = m % 60
        let h12 = h % 12 == 0 ? 12 : h % 12
        return "\(h12)\(mm == 0 ? "" : String(format: ":%02d", mm))\(h < 12 ? "am" : "pm")"
    }

    /// Enough "record it?" answers, nearly all yes, to offer recording calls without asking.
    static func offerAutoRecord(recorded: Int, skipped: Int) -> Bool {
        let total = recorded + skipped
        return total >= 5 && recorded * 5 >= total * 4
    }

    /// The prompt that looks over the user's summary fixes for one standing rule.
    static func rulePrompt(edits: [String], decided: [String]) -> String {
        """
        Below are fixes the user typed into Nikxel's meeting-summary editor over the last 30 days, oldest first.

        Find ONE kind of fix about how meeting summaries should ALWAYS be written -- structure, length, what to include or leave out, how to word things -- that the user asked for at least twice. Ignore one-off corrections of facts in a single summary (a wrong name, a wrong date, a mis-heard word).

        Already suggested to the user -- don't suggest these again or anything that means the same:
        \(decided.isEmpty ? "(none)" : decided.map { "- \($0)" }.joined(separator: "\n"))

        Reply with exactly one line of JSON and nothing else:
        {"rule": "<one instruction for future meeting summaries, imperative, under 20 words>", "times": <how many fixes asked for it>, "example": "<one of the user's fixes, verbatim>"}
        or the single word NONE.

        FIXES:
        \(edits.map { "- \($0)" }.joined(separator: "\n"))
        """
    }

    /// The rule out of the reply to `rulePrompt`, or nil for NONE, prose, or a rule seen fewer than twice.
    static func parseRule(_ reply: String) -> (rule: String, times: Int, example: String)? {
        guard let start = reply.firstIndex(of: "{"), let end = reply.lastIndex(of: "}"),
              let obj = try? JSONSerialization.jsonObject(with: Data(reply[start...end].utf8)) as? [String: Any],
              let rule = (obj["rule"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !rule.isEmpty,
              let times = obj["times"] as? Int, times >= 2 else { return nil }
        return (rule, times, (obj["example"] as? String) ?? "")
    }
}
