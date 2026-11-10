// Runnable check for DayLogger.recentSummaries — the day-window, missing-day
// and truncation logic behind the WhatsApp bot's memory.
//   swiftc -parse-as-library -target arm64-apple-macos15.0 -o /tmp/cbm \
//     src/DayLogger.swift src/NikxelSettings.swift src/NoteExporter.swift \
//     src/MOMGenerator.swift src/UsageLog.swift src/CaptureMode.swift src/Diag.swift \
//     src/ChromeWhatsApp.swift src/CDPClient.swift src/WhatsAppActivityLogger.swift \
//     check_bot_memory.swift && /tmp/cbm
import Foundation

@main struct Check {
    static func main() {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("nikxel-check-\(ProcessInfo.processInfo.processIdentifier)")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // Fixed "now" so the check doesn't drift with the calendar.
        var c = DateComponents(); c.year = 2026; c.month = 11; c.day = 10; c.hour = 12
        let now = Calendar.current.date(from: c)!
        func write(_ day: String, _ text: String) {
            try! text.write(to: dir.appendingPathComponent("\(day).md"), atomically: true, encoding: .utf8)
        }
        func got(_ days: Int, _ cap: Int = 1200) -> [(day: String, text: String)] {
            DayLogger.recentSummaries(days: days, maxCharsPerDay: cap, in: dir, now: now)
        }

        // Yesterday backwards, never today: today's summary isn't written until 10pm.
        write("2026-11-10", "TODAY - must never appear")
        write("2026-11-09", "nine")
        write("2026-11-08", "eight")
        write("2026-11-06", "six")      // the 7th is missing on purpose

        precondition(got(0).isEmpty, "0 days means the feature is off")
        precondition(got(-1).isEmpty, "a negative window must not crash or wrap")

        let one = got(1)
        precondition(one.map(\.day) == ["2026-11-09"], "1 day = yesterday, not today: \(one.map(\.day))")

        let three = got(3)
        precondition(three.map(\.day) == ["2026-11-09", "2026-11-08"],
                     "a missing day is skipped, not substituted: \(three.map(\.day))")

        let four = got(4)
        precondition(four.map(\.day) == ["2026-11-09", "2026-11-08", "2026-11-06"],
                     "newest first, gap skipped: \(four.map(\.day))")

        // Empty and whitespace-only files are not context.
        write("2026-11-05", "   \n  ")
        precondition(got(5).map(\.day) == ["2026-11-09", "2026-11-08", "2026-11-06"],
                     "a blank summary must be dropped")

        // Truncation: these get prepended to every reply prompt.
        write("2026-11-09", String(repeating: "x", count: 5000))
        let capped = got(1, 100)
        precondition(capped[0].text.count == 101, "capped to 100 chars + ellipsis, got \(capped[0].text.count)")
        precondition(capped[0].text.hasSuffix("…"), "truncation must be visible to the model")

        write("2026-11-09", "short")
        precondition(got(1, 100)[0].text == "short", "a short summary must not be altered")

        precondition(DayLogger.recentSummaries(days: 3, in: dir.appendingPathComponent("nope"), now: now).isEmpty,
                     "a missing directory yields no context, not a crash")

        print("check_bot_memory: all cases pass")
    }
}
