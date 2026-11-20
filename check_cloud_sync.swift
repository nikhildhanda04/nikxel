// Runnable check for CloudSync (pure parser, stable id, no-token no-op, pair stores 0600 token).
//   swiftc -parse-as-library -target arm64-apple-macos15.0 -o /tmp/ccs src/CloudSync.swift check_cloud_sync.swift && /tmp/ccs
import Foundation

@main struct Check {
    static func main() {
        let tmp = NSTemporaryDirectory() + "nikxel-cs-" + UUID().uuidString
        try? FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
        setenv("HOME", tmp, 1); setenv("CFFIXED_USER_HOME", tmp, 1)
        var fails = 0
        func check(_ ok: Bool, _ what: String) { if !ok { fails += 1; print("FAIL: \(what)") } else { print("ok: \(what)") } }
        if NSHomeDirectory() != tmp { print("not sandboxed"); exit(1) }

        let md = "## Summary\nBig day on the dashboard.\n\n## What you worked on\n- [coding] **Fixed typing lag** — 1h 30m\n  - found the missing tap re-enable\n- Planning Q4 ~2h\n\n## Meetings\n- 10:30 — Standup 15m\n- None today.\n\n## WhatsApp\n- No calls today.\n- Ravi asked you to send the deck — open\n\n## Open tasks\n- Send deck — for Ravi — open"
        let (headline, items) = CloudSync.dayItems(fromDailySummary: md)
        check(headline == "Big day on the dashboard.", "headline")
        check(items.count == 5, "five items: \(items.count)")
        check(items.first == CloudSync.DayItem(id: items.first?.id ?? "", section: "what you worked on", what: "Fixed typing lag", type: "coding", minutes: 90, details: ["found the missing tap re-enable"]), "item 0")
        check(items.count > 1 && items[1].type == "other" && items[1].minutes == 120, "untagged -> other, 2h")
        check(items.contains { $0.section == "meetings" && $0.type == "meeting" }, "meeting type")
        check(items.first?.id.count == 12 && items == CloudSync.dayItems(fromDailySummary: md).items, "stable 12-hex id")
        check(CloudSync.itemID(section: "a", what: "X") == CloudSync.itemID(section: "a", what: "x") && CloudSync.itemID(section: "a", what: "x") != CloudSync.itemID(section: "b", what: "x"), "id per section, case-insensitive")

        var calls = 0
        check(!CloudSync.pushDay(summary: md, day: "2026-11-20", skip: [], post: { _, _, _ in calls += 1; return nil }) && calls == 0, "pushDay with no token is a no-op")

        check(!CloudSync.pair("123456", post: { _, _, _ in nil }), "pair fails quietly on network failure")
        let ok = CloudSync.pair("123456", post: { p, b, _ in
            (p == "/api/pair" && (b["code"] as? String) == "123456") ? Data(#"{"deviceToken":"tok123"}"#.utf8) : nil })
        check(ok && CloudSync.token == "tok123", "pair stores token")
        let perm = (try? FileManager.default.attributesOfItem(atPath: tmp + "/.nikxel/cloud-token"))?[.posixPermissions] as? Int
        check(perm == 0o600, "token file is 0600")


        var sent: [String: Any]?; var bearer: String?
        let id0 = items[0].id
        let r = CloudSync.pushDay(summary: md, day: "2026-11-20", skip: [id0], post: { _, b, t in sent = b; bearer = t; return Data() })
        let sentItems = sent?["items"] as? [[String: Any]] ?? []
        check(r && bearer == "tok123" && (sent?["kind"] as? String) == "day" && (sent?["date"] as? String) == "2026-11-20", "push body kind/date, bearer")
        check(Set(sent?.keys.map { $0 } ?? []) == ["kind", "date", "headline", "items"], "push body keys")
        check(sentItems.count == 4 && !sentItems.contains { ($0["id"] as? String) == id0 }, "skip drops item")
        check(Set((sentItems.first ?? [:]).keys) == ["id", "section", "what", "type", "minutes", "details"], "item keys")
        check(!CloudSync.pushDay(summary: md, day: "2026-11-20", skip: [], post: { _, _, _ in nil }), "failed POST -> false")
        print(fails == 0 ? "ALL PASS" : "\(fails) FAILED"); exit(fails == 0 ? 0 : 1)
    }
}
