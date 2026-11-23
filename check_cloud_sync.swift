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
        check(items.count == 3, "work + meetings only: \(items.count)")
        check(items.first == CloudSync.DayItem(id: items.first?.id ?? "", section: "what you worked on", what: "Fixed typing lag", type: "coding", minutes: 90, details: ["found the missing tap re-enable"], project: ""), "item 0")
        check(items.count > 1 && items[1].type == "other" && items[1].minutes == 120, "untagged -> other, 2h")
        check(items.contains { $0.section == "meetings" && $0.type == "meeting" }, "meeting type")
        check(!items.contains { ["whatsapp", "open tasks"].contains($0.section) }, "chats and open tasks never sent")
        check(items.first?.id.count == 12 && items == CloudSync.dayItems(fromDailySummary: md).items, "stable 12-hex id")
        check(CloudSync.itemID(section: "a", what: "X") == CloudSync.itemID(section: "a", what: "x") && CloudSync.itemID(section: "a", what: "x") != CloudSync.itemID(section: "b", what: "x"), "id per section, case-insensitive")

        check(CloudSync.itemID(section: "open tasks", what: "Send deck — for Ravi — open") == CloudSync.itemID(section: "open tasks", what: "Send deck — for Ravi — done"), "id ignores the status tail")
        let (h2, i2) = CloudSync.dayItems(fromDailySummary: "## Summary\nLine one\nline two.\n\nignored\n\n## What you worked on\n- [gaming] Played chess")
        check(h2 == "Line one line two.", "wrapped headline: \(h2)")
        check(i2.first?.what == "Played chess" && i2.first?.type == "other", "unknown tag stripped, type other")
        let pm = CloudSync.dayItems(fromDailySummary: "## What you worked on\n- [coding] [[Produce POS]] Fixed sign-out 1h\n- [other] No project here\n\n## ERP tasks\n- [[Produce POS]] Sign-out button — In Progress (due 2026-11-25)\n- [[A ]] weird]] name]] Task — Done").items
        check(pm.count == 4 && pm[0].project == "Produce POS" && pm[0].what == "Fixed sign-out" && pm[0].minutes == 60 && pm[0].type == "coding", "project tag after type tag")
        check(pm.count == 4 && pm[1].project == "", "no project -> empty")
        check(pm.count == 4 && pm[2].section == "erp tasks" && pm[2].type == "planning" && pm[2].project == "Produce POS" && pm[2].what == "Sign-out button — In Progress (due 2026-11-25)", "erp tasks item")
        check(pm.count == 4 && pm[3].project == "A", "odd project name: \(pm.count == 4 ? pm[3].project : "")")

        let est = CloudSync.dayItems(fromDailySummary: "## What you worked on\n- Debugged after the 2h meeting with Ravi (~45m)\n- Wrote report (~1h 20m).\n- Fixed login 30m — Done\n\n## ERP tasks\n- [[Produce POS]] Raise SLA to 2h — In Progress").items
        check(est.count == 4 && est[0].minutes == 45 && est[0].what == "Debugged after the 2h meeting with Ravi", "trailing estimate wins: \(est.first?.minutes ?? -1) \(est.first?.what ?? "")")
        check(est.count == 4 && est[1].minutes == 80 && est[1].what == "Wrote report.", "1h 20m estimate: \(est[1].minutes) \(est[1].what)")
        check(est.count == 4 && est[2].minutes == 30 && est[3].minutes == 0 && est[3].what == "Raise SLA to 2h — In Progress", "erp task names not parsed: \(est.last?.minutes ?? -1) \(est.last?.what ?? "")")

        var calls = 0
        check(!CloudSync.pushDay(summary: md, day: "2026-11-20", skip: [], post: { _, _, _ in calls += 1; return nil }) && calls == 0, "pushDay with no token is a no-op")

        check(!CloudSync.pair("123456", post: { _, _, _ in nil }), "pair fails quietly on network failure")
        let cache = tmp + "/.nikxel/projects.json"
        try? FileManager.default.createDirectory(atPath: tmp + "/.nikxel", withIntermediateDirectories: true)
        try? Data(#"[{"id":"old","name":"Old Org"}]"#.utf8).write(to: URL(fileURLWithPath: cache))
        check(!CloudSync.pair("123456", post: { _, _, _ in nil }) && FileManager.default.fileExists(atPath: cache), "failed pair keeps the cache")
        let nf = CloudSync.projectFeed(get: { _, _ in Data("[]".utf8) })
        check(nf.feed.isEmpty && !nf.offline, "no token -> ([], false)")
        let ok = CloudSync.pair("123456", post: { p, b, _ in
            (p == "/api/pair" && (b["code"] as? String) == "123456") ? Data(#"{"deviceToken":"tok123"}"#.utf8) : nil })
        check(ok && CloudSync.token == "tok123", "pair stores token")
        check(!FileManager.default.fileExists(atPath: cache), "pair clears the previous project cache")
        let perm = (try? FileManager.default.attributesOfItem(atPath: tmp + "/.nikxel/cloud-token"))?[.posixPermissions] as? Int
        check(perm == 0o600, "token file is 0600")


        var sent: [String: Any]?; var bearer: String?
        let id0 = items[0].id
        let r = CloudSync.pushDay(summary: md, day: "2026-11-20", skip: [id0], post: { _, b, t in sent = b; bearer = t; return Data() })
        let sentItems = sent?["items"] as? [[String: Any]] ?? []
        check(r && bearer == "tok123" && (sent?["kind"] as? String) == "day" && (sent?["date"] as? String) == "2026-11-20", "push body kind/date, bearer")
        check(Set(sent?.keys.map { $0 } ?? []) == ["kind", "date", "headline", "items"], "push body keys")
        check(sentItems.count == 2 && !sentItems.contains { ($0["id"] as? String) == id0 }, "skip drops item")
        check(Set((sentItems.first ?? [:]).keys) == ["id", "section", "what", "type", "minutes", "details", "project"], "item keys")
        check(!CloudSync.pushDay(summary: md, day: "2026-11-20", skip: [], post: { _, _, _ in nil }), "failed POST -> false")
        let all = items.map(\.id)
        var hl: [String: Any]?, empty: [String: Any]?
        check(!CloudSync.pushDay(summary: md, day: "d", skip: Set(all), post: { _, _, _ in Data() }), "all skipped, never sent -> false")
        check(CloudSync.pushDay(summary: md, day: "d", skip: Set(all), allowEmpty: true, post: { _, b, _ in empty = b; return Data() }) && (empty?["items"] as? [[String: Any]])?.isEmpty == true, "allowEmpty retracts with items []")
        _ = CloudSync.pushDay(summary: md, day: "d", skip: ["headline"], post: { _, b, _ in hl = b; return Data() })
        check((hl?["headline"] as? String) == "" && (hl?["items"] as? [[String: Any]])?.count == 3, "skip headline blanks it, keeps items")

        // measured stats: owner markers parse to minutes/counts; pushDay carries them, omits when nil
        let sm = CloudSync.statsFromMarkers("# D\n<!--stat computer=17h 6m-->\n<!--stat coding=14h 2m-->\n<!--stat meetings=3-->")
        check(sm["computer"] == 1026 && sm["coding"] == 842 && sm["meetings"] == 3, "stat markers -> minutes/counts: \(sm)")
        check(CloudSync.statMinutes("45m") == 45 && CloudSync.statMinutes("2h") == 120 && CloudSync.statMinutes("9h 7m split") == 547, "statMinutes parses h/m")
        var ws: [String: Any]?
        _ = CloudSync.pushDay(summary: md, day: "d", skip: [], stats: ["coding": 842], post: { _, b, _ in ws = b; return Data() })
        check((ws?["stats"] as? [String: Int]) == ["coding": 842], "pushDay includes stats")
        check(sent?["stats"] == nil, "pushDay omits stats when none")

        let mom = "# Meeting — 21 Nov\n\n## Summary\nShipped it.\n\n## Client Summary\nDear client, all good.\n### Next\n- more\n\n## Action Items\n- [ ] Ravi: fix login"
        let sb = CloudSync.meetingShareBody(mom)
        check(!sb.contains("Client Summary") && !sb.contains("Dear client") && !sb.contains("### Next"), "share body drops the client summary: \(sb)")
        check(sb.contains("## Summary\nShipped it.") && sb.contains("## Action Items\n- [ ] Ravi: fix login") && sb.hasPrefix("# Meeting"), "share body keeps the rest")
        check(CloudSync.meetingShareBody("## Client Summary\nonly") .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "client summary at the end")
        check(CloudSync.meetingShareBody(String(repeating: "é", count: 25000)).utf16.count == 20000, "share body capped at 20000")

        // projects(): token is "tok123" from the pair above.
        check(CloudSync.projects(get: { _, _ in nil }).isEmpty, "no cache, fetch fails -> []")
        var gotPath: String?, gotBearer: String?
        let fresh = CloudSync.projects(get: { p, t in gotPath = p; gotBearer = t; return Data(#"[{"id":"p1","name":"Produce POS"},{"id":"p2","name":"Nikxel"}]"#.utf8) })
        check(fresh == [CloudSync.Project(id: "p1", name: "Produce POS"), CloudSync.Project(id: "p2", name: "Nikxel")] && gotPath == "/api/device/projects" && gotBearer == "tok123", "projects fetched")
        check(CloudSync.projects(get: { _, _ in nil }) == fresh, "fetch fails -> cached list")
        var shared: [String: Any]?, sharePath: String?
        check(CloudSync.shareMeeting(projectID: "p1", meetingID: "2026-11-21-101500", title: "Meeting — 21 Nov", date: "2026-11-21", body: sb,
                                     post: { p, b, _ in sharePath = p; shared = b; return Data() }), "shareMeeting ok")
        check(sharePath == "/api/projects/p1/meetings" && Set(shared?.keys.map { $0 } ?? []) == ["meeting_id", "title", "date", "body"] && (shared?["body"] as? String) == sb, "share request")
        check(!CloudSync.shareMeeting(projectID: "p1", meetingID: "m", title: "t", date: "2026-11-21", body: "b", post: { _, _, _ in nil }), "failed share -> false")

        // projectFeed(): token "tok123".
        let feedCache = tmp + "/.nikxel/project-feed.json"
        check(CloudSync.projectFeed(get: { _, _ in nil }).offline, "no cache, fetch fails -> offline")
        var feedPath: String?
        let ff = CloudSync.projectFeed(get: { p, _ in feedPath = p; return Data(#"[{"id":"p1","name":"POS","days":[]}]"#.utf8) })
        check(ff.feed.count == 1 && !ff.offline && feedPath == "/api/device/projects/feed?days=14" && FileManager.default.fileExists(atPath: feedCache), "feed fetched and cached")
        let fc = CloudSync.projectFeed(get: { _, _ in nil })
        check(fc.feed.count == 1 && !fc.offline, "fetch fails -> cached feed, not offline")
        _ = CloudSync.pair("123456", post: { _, _, _ in Data(#"{"deviceToken":"tok123"}"#.utf8) })
        check(!FileManager.default.fileExists(atPath: feedCache), "pair clears the feed cache")

        print(fails == 0 ? "ALL PASS" : "\(fails) FAILED"); exit(fails == 0 ? 0 : 1)
    }
}
