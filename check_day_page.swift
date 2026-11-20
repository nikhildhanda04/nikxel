// Runnable check for DayPage's daily mode (tags hidden, data-id = CloudSync's id, Send bar).
//   DayPage pulls in most of the app, so it compiles against all of src/ with NikxelApp's @main removed:
//   sed 's/^@main$//' src/NikxelApp.swift > /tmp/NikxelApp.swift && swiftc -parse-as-library -target arm64-apple-macos15.0 \
//     -D NIKXEL_PRIVATE -o /tmp/cdp $(ls src/*.swift | grep -v NikxelApp.swift) /tmp/NikxelApp.swift private/*.swift check_day_page.swift && /tmp/cdp
import Foundation

@main struct CheckDayPage {
    static func main() {
        var fails = 0
        func check(_ ok: Bool, _ what: String) { if !ok { fails += 1; print("FAIL: \(what)") } else { print("ok: \(what)") } }

        let md = "## Summary\nBig day on the dashboard.\n\n## What you worked on\n- [coding] **Fixed typing lag** — 1h 30m\n  - found the missing tap re-enable\n- Planning Q4 ~2h\n\n## Meetings\n- 10:30 — Standup 15m\n- None today.\n\n## WhatsApp\n- No calls today.\n- Ravi asked you to send the deck — open\n\n## Open tasks\n- Send deck — for Ravi — open\n\n## Other\n- [other] Long focus block after lunch\n"
        let html = DayPage.html(from: md, daily: true)
        check(!html.contains("[coding]") && !html.contains("[other]"), "tags hidden")
        check(html.contains("data-id=\"\(CloudSync.itemID(section: "what you worked on", what: "Fixed typing lag"))\""), "bold + duration bullet id")
        let ids = CloudSync.dayItems(fromDailySummary: md).items.map(\.id)
        check(ids.count == 6 && ids.allSatisfy { html.contains("data-id=\"\($0)\"") }, "every dayItems id on the page")
        check(html.components(separatedBy: "data-id=\"").count - 1 == ids.count + 1 && html.contains("<h1 data-id=\"headline\">"), "none-ish bullets get no id; headline crossable")
        check(html.contains("class=\"nx-send\""), "send bar")
        check(html.contains("class=\"nx-todo\""), "open-task checkbox")

        let task = CloudSync.itemID(section: "open tasks", what: "Send deck — for Ravi — open")
        let ticked = DayPage.markTask(in: md, index: 0, done: true) ?? ""
        check(ticked.contains("Ravi — done") && html.contains("data-id=\"\(task)\"") && DayPage.html(from: ticked, daily: true).contains("data-id=\"\(task)\""), "ticking keeps the task's data-id")

        if let r = html.range(of: #"(?<=id="nx-day">).*?(?=</script>)"#, options: .regularExpression),
           let day = try? JSONSerialization.jsonObject(with: Data(html[r].utf8)) as? [String: Any],
           let items = day["items"] as? [[String: Any]] {
            let sent = CloudSync.dayItems(fromDailySummary: md)
            check(day["headline"] as? String == sent.headline && items.map { $0["id"] as? String } == sent.items.map { $0.id }
                  && items.map { $0["type"] as? String } == sent.items.map { $0.type }, "embedded day = what pushDay sends")
        } else { check(false, "embedded day") }
        check(html.contains("<dialog class=\"nx-pv\"") && html.contains("class=\"nx-prev\""), "preview dialog + button")
        let plain = DayPage.html(from: md)
        check(!plain.contains("data-id=") && !plain.contains("class=\"nx-send\"") && !plain.contains("<dialog class=\"nx-pv\"") && !plain.contains("id=\"nx-day\"") && !plain.contains("[coding]"), "not daily: no ids, no bar, no tags")
        check(plain.contains("class=\"nx-todo\""), "not daily: checkbox")
        print(fails == 0 ? "ALL PASS" : "\(fails) FAILED"); exit(fails == 0 ? 0 : 1)
    }
}
