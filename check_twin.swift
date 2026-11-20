// Runnable check for TwinProfile — the learned-profile store and its injected block.
//   swiftc -parse-as-library -target arm64-apple-macos15.0 -o /tmp/ctw \
//     src/TwinProfile.swift check_twin.swift && /tmp/ctw
import Foundation

@main struct Check {
    static func main() {
        let label = "What Nikxel has learned about this user over time — their work, the correct names and terms they use, and how they talk and write. Match it."
        // Never touch the real profile: point HOME at a fresh temp dir before any TwinProfile access.
        let tmp = NSTemporaryDirectory() + "nikxel-twin-" + UUID().uuidString
        try? FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
        setenv("HOME", tmp, 1)
        var fails = 0
        func check(_ ok: Bool, _ what: String) { if !ok { fails += 1; print("FAIL: \(what)") } else { print("ok: \(what)") } }

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
        check(TwinProfile.correct("television revision") == "television revision", "correct respects word boundaries")
        TwinProfile.learned = "no region"
        check(TwinProfile.correct("x") == "x", "no corrections region is a no-op")
        TwinProfile.learned = ""

        check(TwinProfile.selfLines(fromTranscript: "[00:00:01] Me: hello there\n[00:00:04] Priya: hi") == ["hello there"], "selfLines keeps only Me lines, prefix stripped")
        check(TwinProfile.selfLines(fromTranscript: "[00:00:01] Priya: hi\n[00:00:03] Others: yo") == [], "selfLines empty without Me lines")

        if fails > 0 { exit(1) }
    }
}
