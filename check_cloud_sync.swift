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

        let md = """
        # 2026-11-20 — Day in review

        ## Summary
        - 45m of not-a-work-item here

        ## What you worked on
        - **Fixed typing lag** in Nikxel — 1h 30m
        - Shipped invoice fix (45m)
        - Planning the Q4 roadmap ~2h
          - sub detail 10m
        - None today.

        ## Meetings
        - Standup 15m
        """
        let items = CloudSync.workItems(fromDailySummary: md)
        check(items.count == 3, "three work items (drops sub-bullets, None, other sections): \(items.count)")
        check(items.first?.what == "Fixed typing lag in Nikxel" && items.first?.minutes == 90, "1h 30m -> 90")
        check(items.count > 1 && items[1].what == "Shipped invoice fix" && items[1].minutes == 45, "45m -> 45")
        check(items.count > 2 && items[2].minutes == 120, "2h -> 120")
        check(items == CloudSync.workItems(fromDailySummary: md) && items.first?.id.count == 12, "stable 12-hex id")

        var calls = 0
        CloudSync.pushDaily(summary: md, day: "2026-11-20", post: { _, _, _ in calls += 1; return nil })
        check(calls == 0, "pushDaily with no token is a no-op")

        check(!CloudSync.pair("123456", post: { _, _, _ in nil }), "pair fails quietly on network failure")
        let ok = CloudSync.pair("123456", post: { p, b, _ in
            (p == "/api/pair" && (b["code"] as? String) == "123456") ? Data(#"{"deviceToken":"tok123"}"#.utf8) : nil })
        check(ok && CloudSync.token == "tok123", "pair stores token")
        let perm = (try? FileManager.default.attributesOfItem(atPath: tmp + "/.nikxel/cloud-token"))?[.posixPermissions] as? Int
        check(perm == 0o600, "token file is 0600")

        var sent: [String: Any]?; var bearer: String?
        CloudSync.pushDaily(summary: md, day: "2026-11-20", post: { _, b, t in sent = b; bearer = t; return Data() })
        check(bearer == "tok123" && Set((sent ?? [:]).keys) == ["kind", "date", "items"], "push body is only kind/date/items, bearer token")
        let first = (sent?["items"] as? [[String: Any]])?.first
        check(Set((first ?? [:]).keys) == ["id", "what", "minutes"], "item has only id/what/minutes")
        print(fails == 0 ? "ALL PASS" : "\(fails) FAILED"); exit(fails == 0 ? 0 : 1)
    }
}
