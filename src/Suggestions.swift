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
        /// The sidebar flattens newlines and whitespace runs and may end a long preview with "…", so compare on that footing.
        func norm(_ s: String) -> String {
            var n = s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            for e in ["…", "..."] where n.hasSuffix(e) { n = String(n.dropLast(e.count)); break }
            return n.trimmingCharacters(in: .whitespaces)
        }
        let normed = botRows.map { (t: $0.t, name: $0.name, text: norm($0.text)) }
        /// An empty own text (a photo, a sticker) never matches: it's the user's.
        func isBot(_ name: String, _ t: TimeInterval, _ own: String) -> Bool {
            let own = norm(own)
            if own.isEmpty { return false }
            return normed.contains { b in
                guard b.name == name, abs(b.t - t) <= 300 else { return false }
                return own.hasPrefix(String(b.text.prefix(40))) || b.text.hasPrefix(own)
            }
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
                if p.hasPrefix("You:") {
                    if isBot(name, t, String(p.dropFirst(4))) { continue }
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

    /// One foreground-app sample.
    struct Sample { let t: TimeInterval; let app: String; let title: String }
    /// A meeting's span.
    struct Meeting { let start: TimeInterval; let end: TimeInterval; let title: String }

    /// Samples in time order with lock-screen ones dropped.
    private static func awake(_ s: [Sample]) -> [Sample] {
        s.filter { $0.app != "loginwindow" && $0.app != "ScreenSaverEngine" }.sorted { $0.t < $1.t }
    }

    /// App changes between consecutive samples in the same clock hour of the same day; a change across an hour boundary isn't counted.
    private static func switches(_ s: [Sample], _ cal: Calendar) -> [(from: String, to: String, hour: Int)] {
        let a = awake(s)
        var out: [(from: String, to: String, hour: Int)] = []
        for (p, c) in zip(a, a.dropFirst()) where p.app != c.app {
            let pd = cal.dateComponents([.year, .month, .day, .hour], from: Date(timeIntervalSince1970: p.t))
            let cd = cal.dateComponents([.year, .month, .day, .hour], from: Date(timeIntervalSince1970: c.t))
            if pd == cd { out.append((p.app, c.app, pd.hour!)) }
        }
        return out
    }

    /// Hour of day -> average app changes per active hour (an hour is active when it has at least one sample).
    static func switchesByHour(_ s: [Sample], calendar: Calendar = .current) -> [Int: Double] {
        var active = Set<DateComponents>()
        for x in awake(s) { active.insert(calendar.dateComponents([.year, .month, .day, .hour], from: Date(timeIntervalSince1970: x.t))) }
        var hours: [Int: Int] = [:], total: [Int: Int] = [:]
        for d in active { hours[d.hour!, default: 0] += 1 }
        for w in switches(s, calendar) { total[w.hour, default: 0] += 1 }
        return hours.reduce(into: [:]) { $0[$1.key] = Double(total[$1.key] ?? 0) / Double($1.value) }
    }

    /// Unordered app pairs by direct switches between them, most first, ties by name.
    static func topPairs(_ s: [Sample], limit: Int = 5, calendar: Calendar = .current) -> [(a: String, b: String, count: Int)] {
        var n: [[String]: Int] = [:]
        for w in switches(s, calendar) { n[[w.from, w.to].sorted(), default: 0] += 1 }
        let all = n.map { (a: $0.key[0], b: $0.key[1], count: $0.value) }
        return Array(all.sorted { ($1.count, $0.a, $0.b) < ($0.count, $1.a, $1.b) }.prefix(max(0, limit)))
    }

    /// Apps seen within 30 minutes after at least two meetings ended (once per meeting), most first, ties by name.
    static func afterMeetings(_ m: [Meeting], _ s: [Sample]) -> [(app: String, meetings: Int)] {
        let a = awake(s)
        var n: [String: Int] = [:]
        for mt in m {
            for app in Set(a.filter { $0.t >= mt.end && $0.t < mt.end + 1800 }.map(\.app)) { n[app, default: 0] += 1 }
        }
        return n.filter { $0.value >= 2 }.map { (app: $0.key, meetings: $0.value) }.sorted { ($1.meetings, $0.app) < ($0.meetings, $1.app) }
    }
}
