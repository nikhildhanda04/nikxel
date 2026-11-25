// swiftc src/TranscriptHealth.swift checks/check_transcript_health.swift -o /tmp/cth && /tmp/cth
import Foundation

@main struct CheckTranscriptHealth {
    static func main() {
        var fails = 0
        func check(_ ok: Bool, _ what: String) { if !ok { fails += 1; print("FAIL: \(what)") } else { print("ok: \(what)") } }

        // whisper stuck in a loop, as on 2026-11-25.
        var stuck = ""
        for i in 0..<40 { stuck += "\(i + 1)\n00:00:\(String(format: "%02d", i)),000 --> 00:00:\(String(format: "%02d", i + 1)),000\n \(i % 10 == 3 ? "Hello." : "[no audio]")\n\n" }
        let s = TranscriptHealth.analyse(stuck)
        check(s.segments == 40 && s.placeholders == 36 && s.words == 4, "counts segments, placeholders, words (got \(s))")
        check(s.topPlaceholder == "[no audio]" && s.topLine == "hello." && s.topLineCount == 4, "top placeholder and line")
        check(s.longestRun == 9 && s.runLine == "[no audio]", "longest identical run")
        check(TranscriptHealth.describe(stuck).contains("36 placeholders (mostly \"[no audio]\")"), "described (\(TranscriptHealth.describe(stuck)))")

        let fine = "1\n00:00:00,000 --> 00:00:03,000\nWe ship Friday.\n\n2\n00:00:03,000 --> 00:00:05,000\n(laughs) Sure, Ali.\n\n3\n00:00:05,000 --> 00:00:06,000\n[BLANK_AUDIO]\n"
        let f = TranscriptHealth.analyse(fine)
        check(f.segments == 3 && f.words == 5 && f.placeholders == 1 && f.longestRun == 1, "a normal transcript (got \(f))")
        check(!TranscriptHealth.describe(fine).contains("longest run"), "no run noise when there's none")
        check(TranscriptHealth.isPlaceholder("[BLANK_AUDIO]") && TranscriptHealth.isPlaceholder("(music) [no audio]") && !TranscriptHealth.isPlaceholder("(laughs) Sure"), "placeholder lines")
        check(TranscriptHealth.analyse("").segments == 0, "empty")

        print(fails == 0 ? "ALL OK" : "\(fails) FAILED"); exit(fails == 0 ? 0 : 1)
    }
}
