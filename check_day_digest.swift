// Checks the end-of-day digest line: app classification, duration wording, and
// which combinations of stats are worth a bubble at all.
//
//   swiftc -parse-as-library -o /tmp/cdd check_day_digest.swift src/DayLogger.swift \
//     src/MOMGenerator.swift src/UsageLog.swift src/NikxelSettings.swift src/NoteExporter.swift \
//     src/CaptureMode.swift src/Diag.swift src/SummaryTemplates.swift \
//     src/WhatsAppActivityLogger.swift
import Foundation

@main
struct CheckDayDigest {
    typealias S = DayLogger.DayStats

    static func main() {
        // --- Duration wording ----------------------------------------------
        assert(DayLogger.humanDuration(minutes: 200) == "3h 20m")
        assert(DayLogger.humanDuration(minutes: 45) == "45m")
        assert(DayLogger.humanDuration(minutes: 120) == "2h", "a whole number of hours drops the 0m")
        assert(DayLogger.humanDuration(minutes: 0) == "0m")
        assert(DayLogger.humanDuration(minutes: 61) == "1h 1m")

        // --- The line in the mock --------------------------------------------
        let full = S(codingSeconds: 200 * 60, activeSeconds: 400 * 60, meetings: 2, messages: 41)
        assert(DayLogger.digestLine(full) == "3h 20m coding · 2 meetings · 41 messages",
               DayLogger.digestLine(full) ?? "nil")

        // --- Singulars ---------------------------------------------------------
        let one = S(codingSeconds: 60 * 60, activeSeconds: 90 * 60, meetings: 1, messages: 1)
        assert(DayLogger.digestLine(one) == "1h coding · 1 meeting · 1 message",
               DayLogger.digestLine(one) ?? "nil")

        // --- Zero parts are dropped, not shown as "0 meetings" ------------------
        let noMeetings = S(codingSeconds: 95 * 60, activeSeconds: 300 * 60, meetings: 0, messages: 12)
        assert(DayLogger.digestLine(noMeetings) == "1h 35m coding · 12 messages",
               DayLogger.digestLine(noMeetings) ?? "nil")

        // Somebody who never codes still gets a useful bubble.
        let hrDay = S(codingSeconds: 0, activeSeconds: 420 * 60, meetings: 4, messages: 63)
        assert(DayLogger.digestLine(hrDay) == "4 meetings · 63 messages", DayLogger.digestLine(hrDay) ?? "nil")

        // --- Under a minute of coding isn't "0m coding" --------------------------
        let blip = S(codingSeconds: 20, activeSeconds: 200 * 60, meetings: 0, messages: 0)
        assert(DayLogger.digestLine(blip) == "3h 20m at the Mac", DayLogger.digestLine(blip) ?? "nil")

        // --- Fallback and silence -------------------------------------------------
        let idle = S(codingSeconds: 0, activeSeconds: 125 * 60, meetings: 0, messages: 0)
        assert(DayLogger.digestLine(idle) == "2h 5m at the Mac", DayLogger.digestLine(idle) ?? "nil")

        let barely = S(codingSeconds: 0, activeSeconds: 12 * 60, meetings: 0, messages: 0)
        assert(DayLogger.digestLine(barely) == nil, "under half an hour with nothing else = no bubble")
        assert(DayLogger.digestLine(S()) == nil, "an empty day must not produce a bubble")

        // Right on the half-hour boundary the fallback kicks in.
        assert(DayLogger.digestLine(S(activeSeconds: 30 * 60)) == "30m at the Mac")
        assert(DayLogger.digestLine(S(activeSeconds: 29 * 60)) == nil)

        // --- Coding-app classification ---------------------------------------------
        for name in ["Visual Studio Code", "Code - Insiders", "VSCodium", "Xcode", "Cursor",
                     "Terminal", "iTerm2", "Ghostty", "Warp", "Zed", "Sublime Text",
                     "IntelliJ IDEA", "PyCharm", "Android Studio", "Antigravity", "Kiro"] {
            assert(DayLogger.isCodingApp(name), "\(name) should count as coding")
        }
        for name in ["Safari", "Google Chrome", "Slack", "Notion", "Spotify", "Mail",
                     "Figma", "Zoom", "WhatsApp", "Preview", "Finder", "Nikxel"] {
            assert(!DayLogger.isCodingApp(name), "\(name) should NOT count as coding")
        }
        // Matching is case-insensitive, since app names arrive as localizedName.
        assert(DayLogger.isCodingApp("TERMINAL") && DayLogger.isCodingApp("xcode"))

        // --- Bullets pulled onto the "Notes ready" card ----------------------
        let section = """
        - First key point
        -
        - **Second** with `markers` stripped
        - None.
        - Third one
        - Fourth should not appear
        """
        let bullets = MeetingCoordinator.firstBullets(in: section, limit: 3)
        assert(bullets == ["First key point", "Second with markers stripped", "Third one"],
               "got: \(bullets)")
        assert(MeetingCoordinator.firstBullets(in: "", limit: 3).isEmpty)
        assert(MeetingCoordinator.firstBullets(in: "- None.", limit: 3).isEmpty,
               "the \"nothing here\" placeholder is not a bullet")
        assert(MeetingCoordinator.firstBullets(in: "nothing bulleted here", limit: 3).isEmpty)
        // "* " bullets too, since the prompts emit either.
        assert(MeetingCoordinator.firstBullets(in: "* starred", limit: 3) == ["starred"])

        print("check_day_digest: all assertions passed")
    }
}
