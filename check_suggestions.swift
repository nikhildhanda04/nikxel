// Runnable check for Suggestions -- pure logic behind the weekly suggestions.
//   swiftc -parse-as-library -target arm64-apple-macos15.0 -o /tmp/csg src/Suggestions.swift check_suggestions.swift && /tmp/csg
import Foundation

@main struct Check {
    static var failed = false
    static func check(_ ok: Bool, _ what: String) { print(ok ? "ok: \(what)" : "FAIL: \(what)"); if !ok { failed = true } }

    static func main() {
        func row(_ t: Double, _ name: String, _ preview: String) -> [String: Any] { ["t": t, "name": name, "preview": preview] }
        typealias R = Suggestions.Reply

        check(Suggestions.replies(chats: [row(100, "Asha", "hi"), row(400, "Asha", "You: ok")], bot: [])
              == [R(chat: "Asha", group: false, incomingAt: 100, repliedAt: 400)], "incoming then own: replied")
        check(Suggestions.replies(chats: [row(100, "Asha", "hi"), row(220, "Asha", "hello?"), row(400, "Asha", "You: ok")], bot: [])
              == [R(chat: "Asha", group: false, incomingAt: 100, repliedAt: 400)], "second incoming doesn't restart the wait")
        check(Suggestions.replies(chats: [row(50, "Asha", "You: hey"), row(500, "Asha", "hi")], bot: [])
              == [R(chat: "Asha", group: false, incomingAt: 500, repliedAt: nil)], "own first; open wait has no reply")
        let bot: [[String: Any]] = [["t": 240, "name": "Asha", "text": "Sure, I'll check"]]
        check(Suggestions.replies(chats: [row(100, "Asha", "hi"), row(250, "Asha", "You: Sure, I'll check"), row(900, "Asha", "You: me now")], bot: bot)
              == [R(chat: "Asha", group: false, incomingAt: 100, repliedAt: 900)], "bot's own reply doesn't close the wait")
        check(Suggestions.replies(chats: [row(100, "Dev", "Ben: lunch?"), row(160, "Dev", "You: yes")], bot: [])
              == [R(chat: "Dev", group: true, incomingAt: 100, repliedAt: 160)], "group chat detected")
        check(Suggestions.replies(chats: [], bot: []).isEmpty, "empty input")

        let open = R(chat: "Asha", group: false, incomingAt: 100, repliedAt: nil)
        func bots(_ text: String, _ t: Double = 240, _ name: String = "Asha") -> [[String: Any]] { [["t": t, "name": name, "text": text]] }
        check(Suggestions.replies(chats: [row(100, "Asha", "hi"), row(250, "Asha", "You: Sure, I'll check it")], bot: bots("Sure,\nI'll  check it")) == [open], "newlines and whitespace runs flattened: still the bot")
        let long = String(repeating: "abcdefghij", count: 8)
        check(Suggestions.replies(chats: [row(100, "Asha", "hi"), row(250, "Asha", "You: " + long.prefix(30) + "…")], bot: bots(long)) == [open], "preview cut with an ellipsis: still the bot")
        check(Suggestions.replies(chats: [row(100, "Asha", "hi"), row(250, "Asha", "You: ")], bot: bots("Sure", 240)) == [R(chat: "Asha", group: false, incomingAt: 100, repliedAt: 250)], "empty own text is a real reply")
        check(Suggestions.replies(chats: [row(100, "Asha", "hi"), row(250, "Asha", "You:")], bot: bots("Sure", 240)) == [R(chat: "Asha", group: false, incomingAt: 100, repliedAt: 250)], "bare \"You:\" is a real reply")
        check(Suggestions.replies(chats: [row(100, "Asha", "hi"), row(250, "Asha", "You: Sure")], bot: bots("Sure", 240, "Ben")) == [R(chat: "Asha", group: false, incomingAt: 100, repliedAt: 250)], "bot row for another chat: not matched")
        check(Suggestions.replies(chats: [row(100, "Asha", "hi"), row(250, "Asha", "You: Sure")], bot: bots("Sure", 551)) == [R(chat: "Asha", group: false, incomingAt: 100, repliedAt: 250)], "bot row 301s away: not matched")
        check(Suggestions.replies(chats: [row(100, "Asha", "You: a"), row(200, "Asha", "You:")], bot: []).isEmpty, "only own previews: nothing")

        // Activity patterns, pinned to Asia/Kolkata so they pass anywhere.
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "Asia/Kolkata")!
        func at(_ d: Int, _ h: Int, _ m: Int) -> Double { cal.date(from: DateComponents(year: 2026, month: 1, day: d, hour: h, minute: m))!.timeIntervalSince1970 }
        func smp(_ t: Double, _ app: String) -> Suggestions.Sample { .init(t: t, app: app, title: "") }
        let sw = [smp(at(5, 10, 0), "Code"), smp(at(5, 10, 10), "Slack"), smp(at(5, 10, 20), "Code"), smp(at(5, 10, 30), "Slack"), smp(at(5, 11, 0), "Code")]
        check(Suggestions.switchesByHour(sw, calendar: cal) == [10: 3, 11: 0], "switches per active hour; hour-boundary change not counted")
        check(Suggestions.switchesByHour(sw + [smp(at(6, 10, 0), "Code"), smp(at(6, 10, 10), "Slack")], calendar: cal) == [10: 2, 11: 0], "average over days")
        check(Suggestions.switchesByHour([smp(at(5, 10, 0), "Code"), smp(at(5, 10, 5), "loginwindow"), smp(at(5, 10, 10), "Code"), smp(at(5, 10, 15), "ScreenSaverEngine")], calendar: cal) == [10: 0], "lock screen dropped")
        check(Suggestions.switchesByHour([], calendar: cal).isEmpty, "no samples: no hours")
        let pr = Suggestions.topPairs(sw, calendar: cal)
        check(pr.count == 1 && pr[0].a == "Code" && pr[0].b == "Slack" && pr[0].count == 3, "pair Code/Slack x3 (a < b)")
        check(Suggestions.topPairs([smp(1, "B"), smp(2, "A"), smp(3, "C")], limit: 2, calendar: cal).map { "\($0.a)\($0.b)\($0.count)" } == ["AB1", "AC1"], "ties by name, limited")
        check(Suggestions.topPairs(sw, limit: 0, calendar: cal).isEmpty && Suggestions.topPairs([]).isEmpty, "limit 0 and empty")
        func mt(_ end: Double) -> Suggestions.Meeting { .init(start: end - 3600, end: end, title: "m") }
        let am = Suggestions.afterMeetings([mt(1000), mt(10000)],
            [smp(1100, "Odoo"), smp(1200, "Odoo"), smp(1300, "Mail"), smp(10500, "Odoo"), smp(1000 + 1800, "Late")])
        check(am.count == 1 && am[0].app == "Odoo" && am[0].meetings == 2, "after two meetings: Odoo x2 once each; Mail x1 and 30 min edge dropped")
        check(Suggestions.afterMeetings([], [smp(1, "A")]).isEmpty, "no meetings")

        if failed { exit(1) }
    }
}
