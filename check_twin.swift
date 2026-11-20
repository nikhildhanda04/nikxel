// Runnable check for TwinProfile — the learned-profile store and its injected block.
//   swiftc -parse-as-library -target arm64-apple-macos15.0 -o /tmp/ctw \
//     src/TwinProfile.swift src/TwinDistiller.swift check_twin.swift && /tmp/ctw
import Foundation

func cblog(_ msg: String) { print("log: \(msg)") } // stand-in for the app's logger (ChatbotEngine.swift)

@main struct Check {
    static func main() {
        let label = "What Nikxel has learned about this user over time — their work, the correct names and terms they use, and how they talk and write. Match it."
        // Never touch the real profile: point HOME at a fresh temp dir before any TwinProfile access.
        let tmp = NSTemporaryDirectory() + "nikxel-twin-" + UUID().uuidString
        try? FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
        setenv("HOME", tmp, 1)
        setenv("CFFIXED_USER_HOME", tmp, 1) // NSHomeDirectory() on macOS honors this, not HOME
        var fails = 0
        func check(_ ok: Bool, _ what: String) { if !ok { fails += 1; print("FAIL: \(what)") } else { print("ok: \(what)") } }

        print("NSHomeDirectory() = \(NSHomeDirectory())")
        check(NSHomeDirectory() == tmp, "check is sandboxed to temp HOME")
        if NSHomeDirectory() != tmp { exit(1) } // never touch the real home

        TwinProfile.learned = ""
        check(TwinProfile.injectedBlock == "", "empty profile injects nothing")

        TwinProfile.learned = "Works on Vizion Tools."
        let b = TwinProfile.injectedBlock
        check(b.contains(label) && b.contains("Works on Vizion Tools."), "block has label and text")

        TwinProfile.learned = "Keep this.\n<!--corrections-->SECRET<!--/corrections-->\nAnd this."
        let c = TwinProfile.injectedBlock
        check(!c.contains("SECRET") && !c.contains("corrections") && c.contains("Keep this.") && c.contains("And this."), "corrections region stripped")

        let f = NSHomeDirectory() + "/.nikxel/twin/profile.md"
        let perm = (try? FileManager.default.attributesOfItem(atPath: f)[.posixPermissions] as? Int) ?? 0
        check(perm == 0o600, "profile file is 0600")
        TwinProfile.learned = ""
        check(!FileManager.default.fileExists(atPath: f), "empty removes file")

        TwinProfile.learned = "x\n<!--corrections-->\nVision Tools -> Vizion Tools\n<!--/corrections-->"
        check(TwinProfile.correct("We ship vision tools") == "We ship Vizion Tools", "correct is case-insensitive")
        check(TwinProfile.correct("Ship Vision Tools") == "Ship Vizion Tools", "correct wired to learned profile")
        check(TwinProfile.correct("television revision") == "television revision", "correct respects word boundaries")
        TwinProfile.learned = "no region"
        check(TwinProfile.correct("x") == "x", "no corrections region is a no-op")
        TwinProfile.learned = ""

        check(TwinProfile.selfLines(fromTranscript: "[00:00:01] Me: hello there\n[00:00:04] Priya: hi") == ["hello there"], "selfLines keeps only Me lines, prefix stripped")
        check(TwinProfile.selfLines(fromTranscript: "[00:00:01] Priya: hi\n[00:00:03] Others: yo") == [], "selfLines empty without Me lines")

        let sentDir = NSHomeDirectory() + "/.nikxel"
        try? FileManager.default.createDirectory(atPath: sentDir, withIntermediateDirectories: true)
        try? "{\"t\":1,\"text\":\"one\"}\n{\"t\":2,\"text\":\"two\"}\n{\"t\":3,\"text\":\"three\"}\n".write(toFile: sentDir + "/wa_sent.jsonl", atomically: true, encoding: .utf8)
        check(TwinProfile.recentSentMessages(limit: 2) == ["three", "two"], "recentSentMessages newest-first, limited")

        check(TwinDistiller.accept(new: "  \n ", old: "KEEP") == "KEEP", "accept keeps old on empty")
        check(TwinDistiller.accept(new: "Who\n" + String(repeating: "a", count: 5000), old: "x", cap: 3000).count <= 3000, "accept caps length")
        check(TwinDistiller.accept(new: "Who\nl1\nl2\nl3", old: "x", cap: 8) == "Who\nl1", "accept cuts on a line boundary")
        check(TwinDistiller.accept(new: "I can't help with that.", old: "GOOD PROFILE") == "GOOD PROFILE", "accept keeps old on malformed output")
        check(TwinDistiller.accept(new: "## Who\nA dev.", old: "GOOD PROFILE") == "## Who\nA dev.", "accept takes a well-formed profile")
        TwinProfile.learned = "Who\nA dev.\n<!--corrections-->\nvizon -> vizion"
        check(!TwinProfile.injectedBlock.contains("<!--corrections-->") && !TwinProfile.injectedBlock.contains("vizon") && TwinProfile.injectedBlock.contains("A dev."), "unterminated corrections region is stripped")
        let mp = TwinDistiller.mergePrompt(current: "CUR", meetingSelfLines: ["m1"], sentMessages: ["s1"], daySummary: "D1")
        check(["CUR", "m1", "s1", "D1", "<!--corrections-->", "Voice & style", "wrong -> right"].allSatisfy { mp.contains($0) }, "mergePrompt carries inputs and markers")

        TwinProfile.learned = "OLD"
        var calls = 0
        TwinDistiller.distill(meetingSelfLines: [], sentMessages: [], daySummary: "") { _, _ in calls += 1; return "X" }
        check(calls == 0 && TwinProfile.learned == "OLD", "empty signals: no LLM call, profile unchanged")
        TwinDistiller.distill(meetingSelfLines: [], sentMessages: [], daySummary: "did stuff") { _, kind in
            calls += 1; return kind == "twin-distill" ? "Who\nNEW PROFILE" : "BAD" }
        check(calls == 1 && TwinProfile.learned == "Who\nNEW PROFILE", "distill stores the merged profile")
        struct Boom: Error {}
        TwinDistiller.distill(meetingSelfLines: ["hi"], sentMessages: [], daySummary: "") { _, _ in throw Boom() }
        check(TwinProfile.learned == "Who\nNEW PROFILE", "throwing runPrompt leaves profile untouched")
        TwinProfile.learned = ""

        if fails > 0 { exit(1) }
    }
}
