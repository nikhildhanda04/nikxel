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
        let generic: Set<String> = ["group", "team", "chat", "chats", "whatsapp", "official", "community", "with", "from",
                                    "what", "about", "check", "find", "that", "this", "they", "said", "when", "today", "yesterday"]
        // Every word of the name ("Raj") beats a shared word ("Nikxel" of "Nikxel Product Updates").
        let scored = chats.map { name -> (String, Int) in
            let w = words(name)
            return (name, !w.isEmpty && w.isSubset(of: q) ? 100 : w.filter { $0.count >= 4 && !generic.contains($0) && q.contains($0) }.count)
        }
        let best = scored.map(\.1).max() ?? 0
        return best == 0 ? [] : Array(scored.filter { $0.1 == best }.map(\.0).prefix(2))
    }

    /// The day a question asks about, as its start: "today", "yesterday" (any
    /// spelling starting "yest"), "3 days ago", a weekday ("on monday", the last
    /// one before today), or a date ("24th", "on 24", "24 nov", "nov 24"; a
    /// day still to come this month means last month). Nil: no day asked.
    static func day(in question: String, now: Date = Date(), calendar cal: Calendar = .current) -> Date? {
        let q = question.lowercased()
        let w = q.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        let today = cal.startOfDay(for: now)
        func back(_ n: Int) -> Date? { cal.date(byAdding: .day, value: -n, to: today) }
        if let m = q.range(of: #"(\d+) days? ago"#, options: .regularExpression) {
            return Int(q[m].prefix { $0.isNumber }).flatMap(back)
        }
        if w.contains(where: { $0.hasPrefix("yest") }) { return back(w.contains("before") ? 2 : 1) }
        // "24 nov", "24th of november", "nov 24", or alone: "24th", "on 24".
        let months = ["january", "february", "march", "april", "may", "june", "july",
                      "august", "september", "october", "november", "december"]
        func month(_ x: String) -> Int? { x.count >= 3 ? months.firstIndex { $0.hasPrefix(x) }.map { $0 + 1 } : nil }
        let num = #"(\d{1,2})(?:st|nd|rd|th)?"#
        for (rx, n, mo) in [(#"\b"# + num + #"\s+(?:of\s+)?([a-z]+)"#, 1, 2), (#"([a-z]+)\s+"# + num + #"\b"#, 2, 1),
                            (#"\b(\d{1,2})(?:st|nd|rd|th)\b"#, 1, 0), (#"\bon (\d{1,2})\b"#, 1, 0)] {
            guard let re = try? NSRegularExpression(pattern: rx) else { continue }
            for m in re.matches(in: q, range: NSRange(q.startIndex..., in: q)) {
                func group(_ i: Int) -> String? { Range(m.range(at: i), in: q).map { String(q[$0]) } }
                guard let d = group(n).flatMap(Int.init), (1...31).contains(d) else { continue }
                let mm = mo == 0 ? nil : group(mo).flatMap(month)
                if mo != 0 && mm == nil { continue }
                var c = cal.dateComponents([.year, .month], from: today)
                c.day = d
                if let mm { c.month = mm }
                guard var date = cal.date(from: c) else { continue }
                if date > today { date = cal.date(byAdding: mm == nil ? .month : .year, value: -1, to: date) ?? date }
                return date
            }
        }
        let weekdays = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]
        if let i = weekdays.firstIndex(where: w.contains) {
            let n = (cal.component(.weekday, from: today) - 1 - i + 7) % 7
            return back(n == 0 ? 7 : n)
        }
        return w.contains("today") ? today : nil
    }
}
