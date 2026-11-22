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

        // Digest, catalogue and the AI's reply.
        let st = Suggestions.Settings(summaryMinutes: 1320, autoRecordCalls: true, waDraftOnly: false, waQuietHours: true, waQuietFrom: 22, waQuietTo: 8,
                                      waChatTasks: true, summaryTemplate: "default", templates: ["default", "sales"])
        func items(_ json: String, answered: Set<String> = []) -> [Suggestions.Item] { Suggestions.parse(json, settings: st, answered: answered) }
        func offer(_ action: String, _ params: String) -> String { #"{"kind":"offer","action":"\#(action)","params":\#(params),"line":"I'm thinking of it","evidence":"e"}"# }
        let advice = #"{"kind":"advice","text":"Batch Slack","evidence":"40 switches/h"}"#
        check(items("Sure! Here you go:\n```json\n{\"items\":[\(advice),\(offer("summaryTime", #"{"minutes":1560}"#))]}\n```\nHope it helps.")
              == [.advice(text: "Batch Slack", evidence: "40 switches/h"),
                  .offer(action: "summaryTime", params: ["minutes": "1560"], line: "I'm thinking of it", evidence: "e")], "prose and fence around: advice and summaryTime kept")
        check(items(#"{"items":["# + offer("postToSlack", "{}") + "]}").isEmpty, "action outside the catalogue dropped")
        check(items(#"{"items":["# + offer("waQuietHours", #"{"from":22,"to":8}"#) + "]}").isEmpty, "quiet hours as they are: no-op dropped")
        check(items(#"{"items":["# + offer("waQuietHours", #"{"from":"21","to":8}"#) + "]}")
              == [.offer(action: "waQuietHours", params: ["from": "21", "to": "8"], line: "I'm thinking of it", evidence: "e")], "quiet hours changed: kept (string or number)")
        check(items(#"{"items":["# + offer("summaryTemplate", #"{"name":"legal"}"#) + "]}").isEmpty, "template not installed dropped")
        check(items(#"{"items":["# + offer("autoRecordCalls", "{}") + "]}").isEmpty, "autoRecordCalls already on dropped")
        check(items(#"{"items":["# + offer("summaryRule", #"{"text":"Lead with decisions"}"#) + "]}", answered: ["rule:Lead with decisions"]).isEmpty, "answered rule dropped")
        check(items(#"{"items":["# + Array(repeating: advice, count: 5).joined(separator: ",") + "]}").count == 3, "at most 3")
        check(items("NONE").isEmpty, "NONE: nothing")
        check(items(#"{"items":["# + offer("summaryTime", #"{"minutes":1560.5}"#) + "," + offer("summaryTime", #"{"minutes":1320}"#) + "]}").isEmpty, "fractional minutes and current time dropped")
        check(Suggestions.key(action: "waQuietHours", params: ["to": "8", "from": "21"]) == "weekly:waQuietHours:from=21,to=8", "key sorts params")
        check(Suggestions.key(action: "summaryRule", params: ["text": "Lead with decisions"]) == "rule:Lead with decisions", "rule key shared with the daily check")

        let title = String(repeating: "0123456789", count: 20)
        let input = Suggestions.Input(samples: [.init(t: at(5, 10, 0), app: "Code", title: title), .init(t: at(5, 10, 1), app: "Slack", title: "general")],
                                      meetings: [.init(start: at(5, 9, 0), end: at(5, 9, 30), title: "Standup"), .init(start: at(6, 9, 0), end: at(6, 9, 30), title: "Standup")], chats: [row(at(5, 10, 0), "Asha", "pineapple pie"), row(at(5, 10, 30), "Asha", "You: mango"), row(at(5, 11, 0), "Ben", "hey")],
                                      bot: [], edits: ["Put decisions first"], erp: [(day: "2026-01-05", name: "Fix invoice export", project: "Acme")],
                                      settings: st, declined: ["weekly:waDraftOnly:"])
        let dg = Suggestions.digest(input, calendar: cal)
        check(dg.contains(title.prefix(90)) && !dg.contains(title.prefix(91)) && dg.contains("Code"), "digest: titles cut to 90")
        check(!dg.contains("pineapple") && !dg.contains("mango") && dg.contains("Asha"), "digest: chat names but no message text")
        var capped = input
        capped.samples = [.init(t: at(5, 10, 0), app: "Code", title: ""), .init(t: at(5, 10, 20), app: "Slack", title: ""),
                          .init(t: at(5, 10, 22), app: "loginwindow", title: ""), .init(t: at(5, 10, 40), app: "Slack", title: "")]
        capped.declined = (0..<35).map { "k\($0)" }
        let dc = Suggestions.digest(capped, calendar: cal)
        check(dc.contains("- Code: 5 min\n- Slack: 2 min\n") && dc.contains("10:00–10:40"), "digest: gap capped at 5 min, lock screen counts nothing, last sample 15s")
        check(dc.contains("- k5\n") && !dc.contains("- k4\n"), "digest: latest 30 answered keys")
        check(dg == """
        Minutes per app (top 10):
        - Code: 1 min
        - Slack: 0 min

        Minutes per window title (top 10):
        - Code — 012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789: 1 min
        - Slack — general: 0 min

        First and last activity per day:
        - 2026-01-05: 10:00–10:01

        App switches per hour of day (average per active hour):
        - 10:00: 1.0

        Most frequent back-and-forth app pairs:
        - Code ↔ Slack x1

        Meetings (2 this week):
        - start hours: 09:00 x2
        - recurring titles: Standup x2
        - apps opened within 30 min after a meeting: (none)

        WhatsApp reply waits (median minutes, replied messages; 1 replied, 1 unanswered):
        - by hour the message arrived: 10:00 30
        - 1:1 vs group: 1:1 30
        - 5 slowest chats: Asha 30
        - unanswered by day: 2026-01-05 1

        Fixes typed into meeting summaries (last 20):
        - Put decisions first

        ERP tasks logged (last 40):
        - 2026-01-05 Fix invoice export (Acme)

        Current settings:
        - summary time: 10pm (minutes=1320)
        - auto-record calls: on
        - WhatsApp draft-only: off
        - WhatsApp quiet hours: on, from 22 to 8
        - WhatsApp chat tasks: on
        - summary template: default (installed: default, sales)

        Already answered -- don't suggest these again (latest 30):
        - weekly:waDraftOnly:
        """, "digest: whole text, same as the Windows check")

        if failed { exit(1) }
    }
}
