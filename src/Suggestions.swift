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
                    if let c = p.firstIndex(of: ":"), (1...40).contains(p.distance(from: p.startIndex, to: c)), p[p.index(after: c)...].hasPrefix(" ") { group = true }
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

    private static func locked(_ app: String) -> Bool { app == "loginwindow" || app == "ScreenSaverEngine" }
    /// Samples in time order with lock-screen ones dropped.
    private static func awake(_ s: [Sample]) -> [Sample] { s.filter { !locked($0.app) }.sorted { $0.t < $1.t } }

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

    // MARK: The weekly AI review -- digest in, checked items out.

    /// The settings the catalogue can change, as they stand now.
    struct Settings {
        var summaryMinutes: Int; var autoRecordCalls: Bool; var waDraftOnly: Bool; var waQuietHours: Bool; var waQuietFrom: Int; var waQuietTo: Int
        var waChatTasks: Bool; var summaryTemplate: String; var templates: [String]
    }
    /// One week of what Nikxel keeps; `chats`/`bot` are the raw WhatsApp log rows `replies` reads, `declined` the answered keys.
    struct Input {
        var samples: [Sample]; var meetings: [Meeting]; var chats: [[String: Any]]; var bot: [[String: Any]]; var edits: [String]
        var erp: [(day: String, name: String, project: String)]; var settings: Settings; var declined: [String]
    }

    /// One line, at most `n` characters.
    private static func cut(_ s: String, _ n: Int) -> String { String(s.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(n)) }
    /// Lower middle of an even count, so it's always a wait that really happened.
    private static func median(_ x: [Double]) -> Double { x.sorted()[(x.count - 1) / 2] }
    private static func mins(_ seconds: Double) -> Int { Int((seconds / 60).rounded()) }
    private static func hour(_ h: Int) -> String { String(format: "%02d:00", h) }
    /// "10pm", "2:30am" -- `Habits.clock`'s twin, so this file compiles alone.
    private static func clock(_ minutes: Int) -> String {
        let m = minutes % 1440, h = m / 60, mm = m % 60
        return "\(h % 12 == 0 ? 12 : h % 12)\(mm == 0 ? "" : String(format: ":%02d", mm))\(h < 12 ? "am" : "pm")"
    }
    /// Most first, ties by name.
    private static func ranked<T: Comparable>(_ n: [String: T]) -> [(key: String, value: T)] { n.sorted { ($1.value, $0.key) < ($0.value, $1.key) } }

    /// The week as plain text for the AI: counts and times only, titles cut to 90, chat names only among the five slowest, no message text.
    static func digest(_ i: Input, calendar cal: Calendar = .current) -> String {
        func day(_ t: TimeInterval) -> String {
            let c = cal.dateComponents([.year, .month, .day], from: Date(timeIntervalSince1970: t))
            return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
        }
        func hm(_ t: TimeInterval) -> String {
            let c = cal.dateComponents([.hour, .minute], from: Date(timeIntervalSince1970: t))
            return String(format: "%02d:%02d", c.hour!, c.minute!)
        }
        func hr(_ t: TimeInterval) -> Int { cal.component(.hour, from: Date(timeIntervalSince1970: t)) }
        var out: [String] = []
        func section(_ head: String, _ lines: [String]) { out.append(head + ":\n" + (lines.isEmpty ? "(none)" : lines.map { "- " + $0 }.joined(separator: "\n"))) }
        func on(_ b: Bool) -> String { b ? "on" : "off" }
        func list(_ x: [String]) -> String { x.isEmpty ? "(none)" : x.joined(separator: ", ") }

        // The log is written on change, so a sample owns the gap to the next one, capped at 5 min, the last one 15s --
        // as DayLogger counts it. Gaps run over every sample; a lock-screen one then counts for nothing.
        let all = i.samples.sorted { $0.t < $1.t }
        var apps: [String: Double] = [:], windows: [String: Double] = [:], days: [String: (first: TimeInterval, last: TimeInterval)] = [:]
        for (n, x) in all.enumerated() where !locked(x.app) {
            let dur = n + 1 < all.count ? min(all[n + 1].t - x.t, 300) : 15
            apps[x.app, default: 0] += dur
            let t = cut(x.title, 90)
            if !t.isEmpty { windows[x.app + " — " + t, default: 0] += dur }
            let d = day(x.t)
            days[d] = (days[d]?.first ?? x.t, x.t + dur)
        }
        section("Minutes per app (top 10)", ranked(apps).prefix(10).map { "\($0.key): \(mins($0.value)) min" })
        section("Minutes per window title (top 10)", ranked(windows).prefix(10).map { "\($0.key): \(mins($0.value)) min" })
        section("First and last activity per day", days.sorted { $0.key < $1.key }.map { "\($0.key): \(hm($0.value.first))–\(hm($0.value.last))" })
        section("App switches per hour of day (average per active hour)",
                switchesByHour(i.samples, calendar: cal).sorted { $0.key < $1.key }.map { "\(hour($0.key)): \(String(format: "%.1f", $0.value))" })
        section("Most frequent back-and-forth app pairs", topPairs(i.samples, calendar: cal).map { "\($0.a) ↔ \($0.b) x\($0.count)" })

        var starts: [Int: Int] = [:], titles: [String: Int] = [:]
        for m in i.meetings { starts[hr(m.start), default: 0] += 1; titles[cut(m.title, 90), default: 0] += 1 }
        section("Meetings (\(i.meetings.count) this week)", [
            "start hours: " + list(starts.sorted { $0.key < $1.key }.map { "\(hour($0.key)) x\($0.value)" }),
            "recurring titles: " + list(ranked(titles.filter { $0.value >= 2 && !$0.key.isEmpty }).prefix(10).map { "\($0.key) x\($0.value)" }),
            "apps opened within 30 min after a meeting: " + list(afterMeetings(i.meetings, i.samples).prefix(10).map { "\($0.app) (after \($0.meetings))" }),
        ])

        let r = replies(chats: i.chats, bot: i.bot)
        let done = r.compactMap { x in x.repliedAt.map { (x, $0 - x.incomingAt) } }
        let byHour = Dictionary(grouping: done) { hr($0.0.incomingAt) }, byChat = Dictionary(grouping: done) { $0.0.chat }
        let kinds = [("1:1", false), ("group", true)].compactMap { k -> String? in
            let w = done.filter { $0.0.group == k.1 }.map(\.1)
            return w.isEmpty ? nil : "\(k.0) \(mins(median(w)))"
        }
        let unanswered = Dictionary(grouping: r.filter { $0.repliedAt == nil }) { day($0.incomingAt) }
        section("WhatsApp reply waits (median minutes, replied messages; \(done.count) replied, \(r.count - done.count) unanswered)", [
            "by hour the message arrived: " + list(byHour.sorted { $0.key < $1.key }.map { "\(hour($0.key)) \(mins(median($0.value.map(\.1))))" }),
            "1:1 vs group: " + list(kinds),
            "5 slowest chats: " + list(ranked(byChat.mapValues { median($0.map(\.1)) }).prefix(5).map { "\($0.key) \(mins($0.value))" }),
            "unanswered by day: " + list(unanswered.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value.count)" }),
        ])

        section("Fixes typed into meeting summaries (last 20)", i.edits.suffix(20).map { cut($0, 120) })
        section("ERP tasks logged (last 40)", i.erp.suffix(40).map { "\($0.day) \(cut($0.name, 90)) (\(cut($0.project, 90)))" })
        let s = i.settings
        section("Current settings", [
            "summary time: \(clock(s.summaryMinutes)) (minutes=\(s.summaryMinutes))",
            "auto-record calls: \(on(s.autoRecordCalls))",
            "WhatsApp draft-only: \(on(s.waDraftOnly))",
            "WhatsApp quiet hours: \(on(s.waQuietHours)), from \(s.waQuietFrom) to \(s.waQuietTo)",
            "WhatsApp chat tasks: \(on(s.waChatTasks))",
            "summary template: \(s.summaryTemplate) (installed: \(s.templates.joined(separator: ", ")))",
        ])
        section("Already answered -- don't suggest these again (latest 30)", Array(i.declined.suffix(30)))
        return out.joined(separator: "\n\n")
    }

    /// What Nikxel can take on: id, params, what a yes does. `offerParams` is the matching check.
    static let catalogue: [(id: String, params: String, meaning: String)] = [
        ("summaryTime", #"{"minutes": <1080-1740>}"#, "write the daily summary at this time; minutes after midnight, 1080 = 6pm, 1740 = 5am next morning"),
        ("autoRecordCalls", "{}", "record and summarize calls as soon as one starts, instead of asking each time"),
        ("summaryRule", #"{"text": "<instruction, under 120 characters>"}"#, "add a standing instruction for how every meeting summary is written"),
        ("waQuietHours", #"{"from": <0-23>, "to": <0-23>}"#, "the WhatsApp bot doesn't answer between these hours; wraps past midnight when to < from"),
        ("waDraftOnly", "{}", "the WhatsApp bot types its reply into the chat and leaves sending to the person"),
        ("waChatTasks", "{}", "a WhatsApp message that plainly asks for something becomes a Google Task"),
        ("summaryTemplate", #"{"name": "<an installed template>"}"#, "switch to another installed template, which changes how daily, weekly and meeting summaries are written"),
    ]

    /// The weekly review prompt: the digest, the catalogue and who the person is; the reply is one line of JSON.
    static func prompt(digest: String, context: String) -> String {
        """
        Below is a digest of the user's last 7 days, from what Nikxel logs on their computer: apps and window titles, meetings, WhatsApp reply times, ERP tasks, and fixes they typed into meeting summaries.

        Suggest at most 3 things that would make their work easier, each one of two kinds:
        - advice: something they can change themselves.
        - offer: a task Nikxel takes on for them from now on. ONLY the actions in the list below -- never invent one. If the idea isn't on the list, it can only be advice.

        Rules:
        - Ground every item in this person's own numbers from the digest and put them in "evidence" (e.g. "median WhatsApp wait 45 min for messages arriving at 14:00 and 15:00, against 8 min at 10:00"). An item you can't back with a number from the digest is left out.
        - Nothing generic (take breaks, use a to-do list, turn off notifications) unless the digest shows why it fits this person.
        - One sharp item beats three weak ones. If nothing is clearly worth saying, return no items.
        - Don't repeat anything under "Already answered", or anything that means the same.
        - Don't offer what their current settings already do.
        - An offer's "line" is the question Nikxel will ask them, in plain words, starting "I'm thinking of" (e.g. "I'm thinking of writing your daily summary at 1am, since you're usually still working at midnight.").

        WHAT NIKXEL CAN DO (action, params, what a yes does):
        \(catalogue.map { "- \($0.id) \($0.params) -- \($0.meaning)" }.joined(separator: "\n"))

        ABOUT THE USER:
        \(context.isEmpty ? "(nothing given)" : context)

        Reply with exactly one line of JSON and nothing else:
        {"items": [{"kind": "advice", "text": "<what to try, under 30 words>", "evidence": "<their numbers>"}, {"kind": "offer", "action": "<an action from the list>", "params": {<its params>}, "line": "I'm thinking of …", "evidence": "<their numbers>"}]}
        or {"items": []} when nothing is worth saying.

        DIGEST:
        \(digest)
        """
    }

    enum Item: Equatable {
        case advice(text: String, evidence: String)
        case offer(action: String, params: [String: String], line: String, evidence: String)
    }

    /// The answered-key for an offer; a summary rule shares `rule:<text>` and auto-record `autoRecord` with the daily checks.
    static func key(action: String, params: [String: String]) -> String {
        if action == "summaryRule" { return "rule:" + (params["text"] ?? "") }
        if action == "autoRecordCalls" { return "autoRecord" }
        return "weekly:\(action):" + params.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",")
    }

    /// An offer's params checked against the catalogue and written canonically; nil when invalid or when it would change nothing.
    private static func offerParams(_ action: String, _ raw: [String: Any], _ s: Settings) -> [String: String]? {
        func val(_ k: String) -> String? {
            if let v = raw[k] as? String { return v }
            if let n = raw[k] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() { return n.stringValue }  // 1560 or 1560.0, not true
            return nil
        }
        func int(_ k: String, _ r: ClosedRange<Int>) -> Int? { val(k).flatMap { Int($0) }.flatMap { r.contains($0) ? $0 : nil } }
        switch action {
        case "summaryTime":
            guard let m = int("minutes", 1080...1740), m != s.summaryMinutes else { return nil }
            return ["minutes": "\(m)"]
        case "autoRecordCalls": return s.autoRecordCalls ? nil : [:]
        case "waDraftOnly": return s.waDraftOnly ? nil : [:]
        case "waChatTasks": return s.waChatTasks ? nil : [:]
        case "summaryRule":
            guard let t = val("text")?.trimmingCharacters(in: .whitespacesAndNewlines), (1...120).contains(t.count) else { return nil }
            return ["text": t]
        case "waQuietHours":
            guard let f = int("from", 0...23), let t = int("to", 0...23), f != t,
                  !(s.waQuietHours && f == s.waQuietFrom && t == s.waQuietTo) else { return nil }
            return ["from": "\(f)", "to": "\(t)"]
        case "summaryTemplate":
            guard let n = val("name"), s.templates.contains(n), n != s.summaryTemplate else { return nil }
            return ["name": n]
        default: return nil
        }
    }

    /// The items out of the reply to `prompt`: up to 3 in reply order, offers only from the catalogue, valid, changing
    /// something and not answered before. Prose, a code fence or NONE around or instead of the JSON is fine.
    static func parse(_ reply: String, settings: Settings, answered: Set<String>) -> [Item] {
        guard let a = reply.firstIndex(of: "{"), let b = reply.lastIndex(of: "}"), a < b,
              let obj = try? JSONSerialization.jsonObject(with: Data(reply[a...b].utf8)) as? [String: Any],
              let list = obj["items"] as? [Any] else { return [] }
        var out: [Item] = [], seen = Set<String>()
        for case let x as [String: Any] in list where out.count < 3 {
            func str(_ k: String) -> String { ((x[k] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
            switch x["kind"] as? String {
            case "advice":
                if !str("text").isEmpty { out.append(.advice(text: str("text"), evidence: str("evidence"))) }
            case "offer":
                guard !str("line").isEmpty, let p = offerParams(str("action"), x["params"] as? [String: Any] ?? [:], settings) else { continue }
                let k = key(action: str("action"), params: p)
                if answered.contains(k) || !seen.insert(k).inserted { continue }
                if str("action") == "summaryTime", answered.contains("summaryTime") { continue }  // the daily summary-time question was answered  // and not twice in one reply
                out.append(.offer(action: str("action"), params: p, line: str("line"), evidence: str("evidence")))
            default: continue
            }
        }
        return out
    }
}
