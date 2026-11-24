// swiftc src/NoteName.swift src/SummaryLibrary.swift checks/check_summary_library.swift -o /tmp/csl && /tmp/csl
import Foundation

@main struct CheckSummaryLibrary {
    static func main() throws {
        var fails = 0
        func check(_ ok: Bool, _ what: String) { if !ok { fails += 1; print("FAIL: \(what)") } else { print("ok: \(what)") } }

        let fm = FileManager.default, tmp = fm.temporaryDirectory.appendingPathComponent("sl-\(UUID().uuidString)")
        let files = [
            "meetings/2026-11-24-153012.md": "# Meeting — 2026-11-24 15:30\n\n## Summary\n- **Agreed** the Q3 plan.\n",
            "meetings/2026-11-24-153012.html": "<title>x</title>",
            "meetings/2026-11-24-153012.client.html": "",
            "meetings/2026-11-24-153012.transcript.txt": "",
            "meetings/Acme Kickoff 2026-11-25-090000.md": "# Meeting — 2026-11-25 09:00\n",
            "meetings/Acme Kickoff 2026-11-25-090000.html": "",
            "meetings/sample.html": "<html><title>Sample page</title>",
            "notes/2026-11-20-101010.md": "# Lecture notes\n",
            "daily/2026-11-23.md": "# 2026-11-23 — Day in review\n",
            "daily/2026-11-23.html": "",
            "daily/2026-11-23.sent.json": "{}",
            "weekly/2026-11-22.md": "# Week\n",
        ]
        for (path, body) in files {
            let url = tmp.appendingPathComponent(path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try body.write(to: url, atomically: true, encoding: .utf8)
        }
        let all = SummaryLibrary.scan(tmp)
        let byName = Dictionary(all.map { ($0.file.lastPathComponent, $0) }, uniquingKeysWith: { a, _ in a })

        check(all.count == 6, "one entry per summary, client/transcript/sent skipped (got \(all.count))")
        check(byName["2026-11-24-153012.html"]?.title == "Meeting — 2026-11-24 15:30", "title from the md heading, opens the html")
        check(byName["2026-11-24-153012.html"]?.snippet == "Agreed the Q3 plan.", "snippet is the first prose line, unbolded")
        check(byName["Acme Kickoff 2026-11-25-090000.html"]?.title == "Acme Kickoff", "a named stem shows its name")
        check(byName["Acme Kickoff 2026-11-25-090000.html"]?.date == "2026-11-25 09:00", "date from the stamp at the end")
        check(byName["sample.html"]?.title == "Sample page", "no md: the html <title>")
        check(byName["2026-11-20-101010.md"]?.kind == "notes", "md-only note opens the md")
        check(byName["2026-11-23.html"]?.date == "2026-11-23 00:00", "day page dated by its stem")
        let dated = all.filter { $0.file.lastPathComponent != "sample.html" }.map(\.date)
        check(dated == dated.sorted(by: >), "newest first")
        try? fm.removeItem(at: tmp)

        print(fails == 0 ? "ALL OK" : "\(fails) FAILED"); exit(fails == 0 ? 0 : 1)
    }
}
