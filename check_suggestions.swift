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

        if failed { exit(1) }
    }
}
