import Foundation

/// Pure logic behind the weekly suggestions: no settings, files or clock -- everything arrives as arguments.
enum Suggestions {
    /// One wait for a reply: when a chat's message arrived and when the user answered (nil = still waiting).
    struct Reply: Equatable { let chat: String; let group: Bool; let incomingAt: TimeInterval; let repliedAt: TimeInterval? }

    /// Reply times from the chat-list log. The list only shows each chat's latest preview, so a wait opens at the first
    /// incoming after the user's last message and closes at their next one -- except Nikxel's own bot sends, which aren't the user.
    static func replies(chats: [[String: Any]], bot: [[String: Any]]) -> [Reply] {
        func time(_ r: [String: Any]) -> TimeInterval? { (r["t"] as? NSNumber)?.doubleValue }  // JSON may hand back Int or Double
        let botRows = bot.compactMap { r -> (t: TimeInterval, name: String, text: String)? in
            guard let t = time(r), let n = r["name"] as? String, let x = r["text"] as? String else { return nil }
            return (t, n, x)
        }
        func isBot(_ name: String, _ t: TimeInterval, _ own: String) -> Bool {
            botRows.contains { $0.name == name && abs($0.t - t) <= 300 && (own.hasPrefix(String($0.text.prefix(40))) || $0.text.hasPrefix(own)) }
        }
        var byChat: [String: [(t: TimeInterval, preview: String)]] = [:]
        for r in chats {
            guard let t = time(r), let n = r["name"] as? String, let p = r["preview"] as? String else { continue }
            byChat[n, default: []].append((t, p))
        }
        var out: [Reply] = []
        for (name, rows) in byChat {
            var open: TimeInterval? = nil, group = false
            var done: [(at: TimeInterval, reply: TimeInterval?)] = []
            for (t, p) in rows.sorted(by: { $0.t < $1.t }) {
                if p.hasPrefix("You: ") {
                    if isBot(name, t, String(p.dropFirst(5))) { continue }
                    if let o = open { done.append((o, t)); open = nil }
                } else {
                    if open == nil { open = t }
                    // ponytail: heuristic -- a 1:1 message that itself starts "Word: ..." reads as a group; WhatsApp's list doesn't say
                    if let c = p.firstIndex(of: ":"), (1...40).contains(p.distance(from: p.startIndex, to: c)) { group = true }
                }
            }
            if let o = open { done.append((o, nil)) }
            out += done.map { Reply(chat: name, group: group, incomingAt: $0.at, repliedAt: $0.reply) }
        }
        return out.sorted { ($0.incomingAt, $0.chat) < ($1.incomingAt, $1.chat) }
    }
}
