import Foundation

/// The WhatsApp chats a chat question names (ChatSession reads them live).
/// Same logic in windows/src/main/whatsapp/waChatMatch.ts; checks/check_wa_chat_match.swift.
enum WAChatMatch {
    /// Which recent chats a question is about: only a question about messages
    /// ("say", "group", "whatsapp", …), and only chats sharing a word of 4+
    /// letters with it (or all of its name). At most two, the best matches, newest first.
    static func named(in question: String, chats: [String]) -> [String] {
        func words(_ s: String) -> Set<String> {
            Set(s.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty })
        }
        let q = words(question)
        let aboutMessages: Set<String> = ["whatsapp", "wa", "group", "chat", "chats", "message", "messages", "msg", "msgs",
                                          "text", "texted", "say", "said", "says", "saying", "sent", "wrote", "reply",
                                          "replied", "asked", "told", "ping", "pinged", "discussed", "talking"]
        guard !q.isDisjoint(with: aboutMessages) else { return [] }
        let generic: Set<String> = ["group", "team", "chat", "chats", "whatsapp", "official", "community", "with", "from"]
        // Every word of the name ("Raj") beats a shared word ("Nikxel" of "Nikxel Product Updates").
        let scored = chats.map { name -> (String, Int) in
            let w = words(name)
            return (name, !w.isEmpty && w.isSubset(of: q) ? 100 : w.filter { $0.count >= 4 && !generic.contains($0) && q.contains($0) }.count)
        }
        let best = scored.map(\.1).max() ?? 0
        return best == 0 ? [] : Array(scored.filter { $0.1 == best }.map(\.0).prefix(2))
    }
}
