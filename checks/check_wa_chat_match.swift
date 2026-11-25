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
        exit(fails == 0 ? 0 : 1)
    }
}
