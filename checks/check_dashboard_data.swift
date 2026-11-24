// swiftc src/NoteName.swift src/SummaryLibrary.swift src/DashboardData.swift checks/check_dashboard_data.swift -o /tmp/cdd && /tmp/cdd
import Foundation

@main struct CheckDashboardData {
    static func main() throws {
        var fails = 0
        func check(_ ok: Bool, _ what: String) { if !ok { fails += 1; print("FAIL: \(what)") } else { print("ok: \(what)") } }

        let md = """
        # Meeting — 2026-11-24 21:33

        ## Attendees
        - Nikhil (Me): developer
        - **Ali Rajeh** — client
        - Others (1 or more participants)

        ## Action Items
        **Can start now**
        - [ ] **Reshare the WIC documents** — Owner: Ali Rajeh — Due: Not specified
        - [x] **Post the loyalty bug** — Owner: Ali Rajeh — Due: 28 Nov
        - [ ] None

        **Blocked**
        - [ ] **Start WIC testing** (blocked: waiting for docs) — Owner: Nikhil (Me) — Due: Friday

        ## Open Questions
        - [ ] not an action item
        """
        let items = DashboardData.actionItems(md)
        check(items.count == 3, "three action items, None and other sections skipped (got \(items.count))")
        check(items.map(\.n) == [1, 2, 3], "numbered like the page's checkboxes")
        check(items[0] == .init(n: 1, done: false, text: "Reshare the WIC documents", owner: "Ali Rajeh", due: ""), "text unbolded, unset due is empty")
        check(items[1].done && items[1].due == "28 Nov", "ticked item and its due")
        check(items[2].owner == "Nikhil (Me)" && DashboardData.isMe(items[2].owner), "my item")
        let marked = DashboardData.markItem(md, n: 3, done: true) ?? ""
        check(DashboardData.actionItems(marked)[2].done && !DashboardData.actionItems(marked)[0].done, "tick the third, only the third")
        check(marked.contains("- [ ] not an action item"), "other sections untouched")
        check(DashboardData.markItem(md, n: 9, done: true) == nil, "no such item")
        check(DashboardData.attendees(md) == ["Ali Rajeh"] && DashboardData.person("Piyush *(likely)*") == "Piyush" && DashboardData.person("Speaker 2") == nil && DashboardData.person("Nikhil's side") == nil, "attendees without me or others, names cleaned (got \(DashboardData.attendees(md)))")

        let fm = FileManager.default, tmp = fm.temporaryDirectory.appendingPathComponent("dd-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        let a = tmp.appendingPathComponent("a.md"), b = tmp.appendingPathComponent("b.md")
        try md.write(to: a, atomically: true, encoding: .utf8)
        try "# Other\n- lunch with Priya".write(to: b, atomically: true, encoding: .utf8)
        let found = DashboardData.search("wic docs", in: [("A", a), ("B", b)])
        check(found.count == 1 && found[0]["id"] == "A", "every word must appear")
        check(found.first?["match"]?.contains("WIC") == true, "match is a readable line (got \(found.first?["match"] ?? ""))")
        try #"{"t":1,"name":"Ali","text":"hi"}"# .appending("\n").appending(#"{"t":2,"name":"Priya","text":"later"}"#)
            .write(to: tmp.appendingPathComponent("bot-2026-11-24.jsonl"), atomically: true, encoding: .utf8)
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        let replies = DashboardData.botReplies(on: f.date(from: "2026-11-24")!, in: tmp)
        check(replies.map { $0["name"] as? String } == ["Priya", "Ali"], "bot replies newest first")
        try? fm.removeItem(at: tmp)

        print(fails == 0 ? "ALL OK" : "\(fails) FAILED"); exit(fails == 0 ? 0 : 1)
    }
}
