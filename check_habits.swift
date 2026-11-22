// Runnable check for Habits -- what Nikxel would suggest from habits and edits.
//   swiftc -parse-as-library -target arm64-apple-macos15.0 -o /tmp/chb src/Habits.swift check_habits.swift && /tmp/chb
import Foundation

@main struct Check {
    static var failed = false
    static func check(_ ok: Bool, _ what: String) { print(ok ? "ok: \(what)" : "FAIL: \(what)"); if !ok { failed = true } }

    static func main() {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "Asia/Kolkata")!
        func at(_ day: Int, _ h: Int, _ m: Int = 0) -> TimeInterval {
            cal.date(from: DateComponents(year: 2026, month: 11, day: day, hour: h, minute: m))!.timeIntervalSince1970
        }
        let samples: [(t: TimeInterval, app: String)] = [
            (at(10, 11), "Code"), (at(10, 23), "Code"), (at(11, 1, 30), "Dia"),  // Nov 10 ends 1:30am → 1530
            (at(11, 3), "loginwindow"),                                           // the lock screen isn't work
            (at(11, 10), "Code"), (at(11, 21), "Slack"),                           // Nov 11 ends 9pm → 1260
            (at(12, 9), "Code"),                                                   // today, unfinished
        ]
        let ends = Habits.dayEnds(samples, now: Date(timeIntervalSince1970: at(12, 15)), calendar: cal).sorted()
        check(ends == [1260, 1530], "dayEnds: 6am-to-6am days, lock screen ignored, today left out (\(ends))")

        check(Habits.summaryTime(dayEnds: [1500, 1530, 1560, 1440, 1590, 1380, 1520], current: 1320) == 1560,
              "late nights: median 1:20am (1520) → 2am (1560)")
        check(Habits.summaryTime(dayEnds: [1500, 1530, 1560], current: 1320) == nil, "fewer than 7 days: no suggestion")
        check(Habits.summaryTime(dayEnds: Array(repeating: 1200, count: 10), current: 1320) == nil, "done by 8pm: keep 10pm")
        check(Habits.summaryTime(dayEnds: Array(repeating: 1360, count: 10), current: 1440) == nil, "within the hour of the current time: no suggestion")
        check(Habits.summaryTime(dayEnds: Array(repeating: 1440 + 400, count: 10), current: 1320) == 1440 + 300, "never past 5am")
        check(Habits.clock(1590) == "2:30am" && Habits.clock(1380) == "11pm" && Habits.clock(1440) == "12am", "clock")

        check(Habits.offerAutoRecord(recorded: 5, skipped: 0), "5 of 5 recorded: offer")
        check(Habits.offerAutoRecord(recorded: 8, skipped: 2), "8 of 10: offer")
        check(!Habits.offerAutoRecord(recorded: 4, skipped: 0), "too few answers")
        check(!Habits.offerAutoRecord(recorded: 6, skipped: 3), "a third skipped: don't")

        let p = Habits.rulePrompt(edits: ["merge related action items"], decided: ["Keep it short"])
        check(p.contains("merge related action items") && p.contains("- Keep it short") && p.contains("NONE"), "rulePrompt carries edits and decided rules")
        let r = Habits.parseRule(#"{"rule": "Merge related action items into one.", "times": 3, "example": "merge 2 and 4"}"#)
        check(r?.rule == "Merge related action items into one." && r?.times == 3 && r?.example == "merge 2 and 4", "parseRule reads the JSON")
        check(Habits.parseRule("NONE") == nil, "NONE: no rule")
        check(Habits.parseRule(#"{"rule": "x", "times": 1, "example": ""}"#) == nil, "asked once: no rule")
        check(Habits.parseRule("Sure! Here you go: {\"rule\": \"Be brief.\", \"times\": 2}")?.rule == "Be brief.", "JSON inside prose")

        if failed { exit(1) }
        print("ALL PASS")
    }
}
