// Runnable check for ChatContext (local blocks, cap rule, prompt).
//   swiftc -parse-as-library -target arm64-apple-macos15.0 -o /tmp/ccc src/ChatContext.swift src/CloudSync.swift check_chat_context.swift && /tmp/ccc
import Foundation

@main struct Check {
    static func main() {
        var fails = 0
        func check(_ ok: Bool, _ what: String) { if !ok { fails += 1; print("FAIL: \(what)") } else { print("ok: \(what)") } }
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
        let today = Date()
        func day(_ n: Int) -> String { f.string(from: Calendar.current.date(byAdding: .day, value: -n, to: today)!) }
        let root = URL(fileURLWithPath: NSTemporaryDirectory() + "nikxel-cc-" + UUID().uuidString)
        let fm = FileManager.default
        func put(_ rel: String, _ s: String) {
            let u = root.appendingPathComponent(rel)
            try? fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? s.write(to: u, atomically: true, encoding: .utf8)
        }
        put("daily/\(day(0)).md", "daily body")
        put("meetings/\(day(1))-101500.md", "meeting body")
        put("meetings/\(day(1))-101500.transcript.txt", "transcript")
        put("notes/\(day(20))-0900.md", "old note")
        put("notes/junk.md", "junk")
        let bs = ChatContext.localBlocks(root: root, today: today)
        check(bs.map(\.kind) == ["daily", "meeting"] && bs[0].date == day(0) && bs[1].name == "\(day(1))-101500", "2 blocks: daily today, meeting: \(bs.map(\.kind))")
        try? fm.removeItem(at: root.appendingPathComponent("notes"))
        check(ChatContext.localBlocks(root: root, today: today).count == 2, "missing notes folder")
        check(ChatContext.localBlocks(root: root.appendingPathComponent("nope"), today: today).isEmpty, "missing root")

        let pad = String(repeating: "x", count: 60)
        let old = ChatContext.Block(kind: "daily", date: day(10), name: day(10), text: pad)
        let mtg = ChatContext.Block(kind: "meeting", date: day(3), name: "m", text: pad)
        let dly = ChatContext.Block(kind: "daily", date: day(0), name: day(0), text: pad)
        let out = ChatContext.build([old, mtg, dly], cap: 200)
        check(out.count <= 200 && !out.contains(day(10)) && out.contains("### meeting · \(day(3)) · m") && out.contains("### daily · \(day(0))"), "old daily dropped first, within cap")
        check(out.range(of: "### daily")!.lowerBound < out.range(of: "### meeting")!.lowerBound, "newest first")
        check(ChatContext.build([mtg, dly], cap: 50).count <= 50, "never over cap")
        let pb = ChatContext.projectBlocks([["id": "p", "name": "POS", "days": [["date": "2026-11-20", "meetings": [["title": "Sync", "body": "b", "name": "Ravi"]], "items": [["what": "Fixed login", "section": "x", "name": NSNull()]]]]]])
        check(pb.count == 1 && pb[0].kind == "project" && pb[0].name == "POS" && pb[0].text.contains("Sync") && pb[0].text.contains("Fixed login"), "project block")

        let p = ChatContext.prompt(context: "CTX", history: [(q: "first?", a: "one")], question: "second?", today: today)
        check(p.contains(day(0)) && p.contains("first?") && p.contains("one") && p.hasSuffix("second?"), "prompt")

        check(ChatContext.clickDecision(moved: 0, secondClick: false) == .chat, "click: still press opens chat")
        check(ChatContext.clickDecision(moved: 3.9, secondClick: false) == .chat, "click: 3.9 pt opens chat")
        check(ChatContext.clickDecision(moved: 5, secondClick: false) == .none, "click: 5 pt is a drag")
        check(ChatContext.clickDecision(moved: 0, secondClick: true) == .none, "click: second click is a double-click")

        print(fails == 0 ? "ALL PASS" : "\(fails) FAILED"); exit(fails == 0 ? 0 : 1)
    }
}
