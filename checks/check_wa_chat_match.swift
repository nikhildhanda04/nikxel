// swiftc src/WAChatMatch.swift checks/check_wa_chat_match.swift -o /tmp/cwm && /tmp/cwm
import Foundation

@main struct CheckWAChatMatch {
    static func main() {
        var fails = 0
        func check(_ ok: Bool, _ what: String) { if !ok { fails += 1; print("FAIL: \(what)") } else { print("ok: \(what)") } }
        let chats = ["Nikxel Product Updates", "piyush co-founder forklyft", "Raj", "Family Group", "Dev Team"]

        check(WAChatMatch.named(in: "what did piyush say in the nikxel whatsapp group", chats: chats)
              == ["Nikxel Product Updates", "piyush co-founder forklyft"], "both named chats, newest first")
        check(WAChatMatch.named(in: "what did Raj say about the nikxel build?", chats: chats) == ["Raj"], "a whole name beats a shared word")
        check(WAChatMatch.named(in: "summarise my nikxel meeting", chats: chats).isEmpty, "not about messages: no chat opened")
        check(WAChatMatch.named(in: "any messages in the group today?", chats: chats).isEmpty, "generic words alone match nothing")
        check(WAChatMatch.named(in: "what did they say", chats: []).isEmpty, "no chats")
        check(WAChatMatch.named(in: "can you check yesterdays msgs and find what he said", chats: ["Find My Phone", "About Town"]).isEmpty, "common words name no chat")

        // The day asked about, from Wed 25 Nov 2026.
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        func d(_ y: Int, _ m: Int, _ day: Int) -> Date { cal.date(from: DateComponents(year: y, month: m, day: day))! }
        let now = d(2026, 11, 25).addingTimeInterval(15 * 3600)
        func day(_ q: String) -> Date? { WAChatMatch.day(in: q, now: now, calendar: cal) }
        check(day("can you check yestaradys msgs") == d(2026, 11, 24), "yesterday, misspelt")
        check(day("what did he say about wic on 24th") == d(2026, 11, 24), "24th")
        check(day("what was said on 3") == d(2026, 11, 3), "on 3")
        check(day("messages from 28th") == d(2026, 10, 28), "a day still to come: last month")
        check(day("what did raj say on 2nd dec") == d(2025, 12, 2), "a month still to come: last year")
        check(day("what did raj say nov 20") == d(2026, 11, 20), "nov 20")
        check(day("messages from 2 days ago") == d(2026, 11, 23), "2 days ago")
        check(day("what did they say on monday") == d(2026, 11, 23), "monday")
        check(day("what did they say today") == d(2026, 11, 25), "today")
        check(day("call at 5 pm, 2026 plans") == nil, "times and years are no day")
        check(day("what did he say") == nil, "no day")
        exit(fails == 0 ? 0 : 1)
    }
}
