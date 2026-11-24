// swiftc src/NoteName.swift checks/check_note_name.swift -o /tmp/cnn && /tmp/cnn
import Foundation

@main struct CheckNoteName {
    static func main() throws {
        var fails = 0
        func check(_ ok: Bool, _ what: String) { if !ok { fails += 1; print("FAIL: \(what)") } else { print("ok: \(what)") } }

        check(NoteName.clean("\"Q3 Budget: Review/Plan\"\nextra") == "Q3 Budget ReviewPlan", "first line, no quotes or path chars")
        check(NoteName.clean("  ..hidden  ") == "hidden", "no leading dots")
        check(NoteName.clean(String(repeating: "a", count: 90)).count == 60, "capped at 60")
        check(NoteName.stamp("Acme Kickoff 2026-11-24-153012") == "2026-11-24-153012" && NoteName.stamp("2026-11-24-1530") == "2026-11-24-1530", "stamp found at the end")
        check(NoteName.isUnnamed("2026-11-24-153012") && !NoteName.isUnnamed("2026-11-24-153012 Foo") && !NoteName.isUnnamed("2026-11-24"), "unnamed = bare timestamp")

        let fm = FileManager.default, tmp = fm.temporaryDirectory.appendingPathComponent("nn-\(UUID().uuidString)")
        let dir = tmp.appendingPathComponent("meetings"), edits = tmp.appendingPathComponent("edits")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try fm.createDirectory(at: edits.appendingPathComponent("2026-11-24-153012"), withIntermediateDirectories: true)
        for f in ["2026-11-24-153012.md", "2026-11-24-153012.html", "2026-11-24-153012.transcript.txt", "2026-11-24-160000.md"] {
            try "x".write(to: dir.appendingPathComponent(f), atomically: true, encoding: .utf8)
        }
        let page = try NoteName.rename(dir.appendingPathComponent("2026-11-24-153012.html"), to: "Acme Kickoff", editsDir: edits)
        let names = Set(try fm.contentsOfDirectory(atPath: dir.path))
        check(page.lastPathComponent == "Acme Kickoff 2026-11-24-153012.html", "returns renamed page")
        check(names == ["Acme Kickoff 2026-11-24-153012.md", "Acme Kickoff 2026-11-24-153012.html",
                        "Acme Kickoff 2026-11-24-153012.transcript.txt", "2026-11-24-160000.md"], "every sibling renamed, others untouched")
        check(fm.fileExists(atPath: edits.appendingPathComponent("Acme Kickoff 2026-11-24-153012").path), "edit history follows")
        check((try? NoteName.rename(page, to: "Again", editsDir: edits)) == nil, "can't rename twice")
        check((try? NoteName.rename(dir.appendingPathComponent("2026-11-24-160000.md"), to: "!!", editsDir: edits)) == nil, "needs a letter or number")
        try? fm.removeItem(at: tmp)

        print(fails == 0 ? "ALL OK" : "\(fails) FAILED"); exit(fails == 0 ? 0 : 1)
    }
}
