import AppKit
import Foundation

/// What Nikxel learned from habits and edits, offered before anything changes: "I'm thinking
/// of… Will this suit you better?" A yes applies it; a no is remembered and never asked again;
/// at most one question a day. Habits.swift decides what to suggest. State in
/// ~/.nikxel/learning.json, the user's summary fixes in ~/.nikxel/edits/instructions.jsonl.
/// Mirrors windows/src/main/system/learning.ts.
enum Learning {
    private static let file = URL(fileURLWithPath: NSHomeDirectory() + "/.nikxel/learning.json")
    private static let editsFile = URL(fileURLWithPath: NSHomeDirectory() + "/.nikxel/edits/instructions.jsonl")
    private static let lock = NSLock()

    private static func load() -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(contentsOf: file))) as? [String: Any] ?? [:]
    }

    private static func update(_ change: (inout [String: Any]) -> Void) {
        lock.lock(); defer { lock.unlock() }
        var s = load()
        change(&s)
        if let data = try? JSONSerialization.data(withJSONObject: s, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: file, options: .atomic)
        }
    }

    private static func dayKey(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f.string(from: d)
    }

    // MARK: - Asking

    /// Asks unless `key` was answered before or something was already asked today. True when it asked.
    @discardableResult
    static func offer(key: String, title: String, line: String, apply: @escaping () -> Void) -> Bool {
        let today = dayKey(Date())
        var asked = false
        update { s in
            guard (s["answered"] as? [String: Bool])?[key] == nil, s["askedDay"] as? String != today else { return }
            s["askedDay"] = today
            asked = true
        }
        guard asked else { return false }
        cblog("Learning: asking \(key)")
        NikxelView.ask(icon: "💡", title: title, lines: [line, "Will this suit you better?"], buttons: [
            ("Yes, do it", { answer(key, true); apply() }),
            ("No thanks", { answer(key, false) }),
        ])
        return true
    }

    private static func answer(_ key: String, _ yes: Bool) {
        cblog("Learning: \(key) → \(yes ? "yes" : "no")")
        update { s in
            var a = s["answered"] as? [String: Bool] ?? [:]; a[key] = yes; s["answered"] = a
            // A JSON object keeps no order, so the order answers came in is kept beside it for the weekly "latest 30".
            var o = s["answeredOrder"] as? [String] ?? []
            if !o.contains(key) { o.append(key) }
            s["answeredOrder"] = o
        }
    }

    static func count(_ name: String) {
        update { s in var c = s["counts"] as? [String: Int] ?? [:]; c[name, default: 0] += 1; s["counts"] = c }
    }

    private static func counter(_ name: String) -> Int { (load()["counts"] as? [String: Int])?[name] ?? 0 }

    // MARK: - Edits

    /// One fix the user typed into a summary's Edit box, kept so repeated ones can become a standing rule.
    static func logEdit(_ instruction: String, page: URL) {
        let p = page.path
        let kind = p.contains("/meetings/") ? "meeting" : p.contains("/daily/") ? "daily" : p.contains("/weekly/") ? "weekly" : "notes"
        let entry: [String: Any] = ["t": Date().timeIntervalSince1970, "kind": kind, "text": instruction]
        guard var line = try? JSONSerialization.data(withJSONObject: entry) else { return }
        line.append(0x0A)
        try? FileManager.default.createDirectory(at: editsFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let h = try? FileHandle(forWritingTo: editsFile) {
            h.seekToEndOfFile(); h.write(line); try? h.close()
        } else {
            try? line.write(to: editsFile, options: .atomic)
        }
    }

    private static func edits(since: Date, kinds: Set<String>? = nil) -> [(t: TimeInterval, text: String)] {
        guard let content = try? String(contentsOf: editsFile, encoding: .utf8) else { return [] }
        return content.split(separator: "\n").compactMap { line in
            guard let o = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let t = o["t"] as? TimeInterval, t >= since.timeIntervalSince1970, let text = o["text"] as? String,
                  kinds.map({ $0.contains(o["kind"] as? String ?? "") }) ?? true else { return nil }
            return (t, text)
        }
    }

    /// The day's summary fixes, for the profile merge: "Speaker 2 is Prince" teaches a name.
    static func editsBlock(since: Date) -> String {
        let e = edits(since: since)
        return e.isEmpty ? "" : "\n\nFixes the user typed into their summaries (names and terms here are corrections worth learning):\n"
            + e.map { "- \($0.text)" }.joined(separator: "\n")
    }

    // MARK: - Once a day

    /// After the day summary: the first thing worth asking about, if any. Off the main thread.
    static func daily(dayLogger: DayLogger, agent: MOMGenerator) {
        DispatchQueue.global(qos: .utility).async {
            if offerSummaryTime(dayLogger) || offerAutoRecord() || offerRule(agent) { return }
            offerQueued(dayLogger)
        }
    }

    private static func offerSummaryTime(_ dayLogger: DayLogger) -> Bool {
        let current = NikxelSettings.summaryMinutes
        guard let t = Habits.summaryTime(dayEnds: Habits.dayEnds(dayLogger.recentSamples(), now: Date()), current: current) else { return false }
        return offer(key: "summaryTime", title: "Your day summary",
                     line: "You usually wrap up by about \(Habits.clock(t - 30)). I'm thinking of writing your day summary at \(Habits.clock(t)) instead of \(Habits.clock(current)).") {
            NikxelSettings.summaryMinutes = t
            DispatchQueue.main.async { dayLogger.reschedule() }
        }
    }

    private static func offerAutoRecord() -> Bool {
        let recorded = counter("call.record"), skipped = counter("call.skip")
        guard !NikxelSettings.autoRecordCalls, Habits.offerAutoRecord(recorded: recorded, skipped: skipped) else { return false }
        return offer(key: "autoRecord", title: "Recording your calls",
                     line: "You've recorded \(recorded) of the \(recorded + skipped) calls I asked about. I'm thinking of starting the recording myself when a call begins — you'll see it, and a double-click stops it.") {
            NikxelSettings.autoRecordCalls = true
        }
    }

    /// Repeated summary fixes → one standing rule for meeting summaries, added to the active
    /// summary template on a yes. Looks only when there are fixes it hasn't looked at.
    private static func offerRule(_ agent: MOMGenerator) -> Bool {
        let recent = edits(since: Date().addingTimeInterval(-30 * 86_400), kinds: ["meeting", "notes"])
        let reviewed = load()["reviewedEditsAt"] as? TimeInterval ?? 0
        guard recent.count >= 2, let newest = recent.map(\.t).max(), newest > reviewed else { return false }
        update { $0["reviewedEditsAt"] = newest }
        let decided = (load()["answered"] as? [String: Bool] ?? [:]).keys.filter { $0.hasPrefix("rule:") }.map { String($0.dropFirst(5)) }
        guard let reply = try? agent.runPrompt(Habits.rulePrompt(edits: recent.map(\.text), decided: decided),
                                               kind: "learning-rule", claudeModel: "haiku"),
              let r = Habits.parseRule(reply) else { return false }
        return offer(key: "rule:" + r.rule, title: "Your meeting summaries",
                     line: "You've asked me this \(r.times) times\(r.example.isEmpty ? "" : " (\"\(r.example)\")"). I'm thinking of always doing it in your meeting summaries: \(r.rule)") {
            addRule(r.rule)
        }
    }

    /// A standing instruction appended to the active summary template -- a yes from the daily rule check or the weekly review.
    private static func addRule(_ rule: String) {
        let url = SummaryTemplates.activeURL
        let old = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        try? (old + (old.hasSuffix("\n") || old.isEmpty ? "" : "\n") + "\n# Added by Nikxel after you said yes (\(dayKey(Date()))):\n\(rule)\n")
            .write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - Once a week

    /// The catalogue's settings as they stand now.
    private static func settingsNow() -> Suggestions.Settings {
        Suggestions.Settings(summaryMinutes: NikxelSettings.summaryMinutes, autoRecordCalls: NikxelSettings.autoRecordCalls,
                             waDraftOnly: NikxelSettings.waDraftOnly, waQuietHours: NikxelSettings.waQuietHours,
                             waQuietFrom: NikxelSettings.waQuietFrom, waQuietTo: NikxelSettings.waQuietTo, waChatTasks: NikxelSettings.waChatTasks,
                             summaryTemplate: NikxelSettings.summaryTemplate, templates: SummaryTemplates.available().map(\.slug))
    }

    /// Meetings whose file name dates them in `days`: start from the name, end from the file's last write, title from its "# " line.
    private static func meetings(on days: Set<String>) -> [Suggestions.Meeting] {
        let dir = URL(fileURLWithPath: NSHomeDirectory() + "/Documents/nikxel/meetings")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        let long = DateFormatter(), short = DateFormatter()
        long.dateFormat = "yyyy-MM-dd-HHmmss"; short.dateFormat = "yyyy-MM-dd-HHmm"
        return names.compactMap { name in
            let stem = String(name.dropLast(3)), stamp = NoteName.stamp(stem), url = dir.appendingPathComponent(name)
            guard name.hasSuffix(".md"), !name.contains(".transcript"), days.contains(String(stamp.prefix(10))) else { return nil }
            guard let start = long.date(from: stamp) ?? short.date(from: stamp),
                  let end = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date,
                  end.timeIntervalSince(start) <= 4 * 3600 else { return nil }  // a later edit of the summary moves the write time: not a real end
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            let title = text.split(separator: "\n").first { $0.hasPrefix("# ") }.map { String($0.dropFirst(2)) } ?? stem
            return Suggestions.Meeting(start: start.timeIntervalSince1970, end: end.timeIntervalSince1970, title: title)
        }
    }

    /// The weekly review, run inside the week in review's background work: the week's digest to the AI once per `weekKey`,
    /// advice back as an "## Ideas for you" section, offers queued for `offerQueued`. "" when there's nothing or it already ran.
    static func weekly(dayLogger: DayLogger, agent: MOMGenerator, weekKey: String) -> String {
        var fresh = false, shown = ""
        update { s in  // before the call: never twice; a repeat gets the ideas already shown
            if s["suggestedWeek"] as? String == weekKey { shown = s["suggestedIdeas"] as? String ?? ""; return }
            s["suggestedWeek"] = weekKey; s["suggestedIdeas"] = ""; fresh = true
        }
        guard fresh else { return shown }
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        let end = f.date(from: weekKey) ?? Date()  // that day's midnight: the seven days before it are the week's
        let days = (1...7).compactMap { Calendar.current.date(byAdding: .day, value: -$0, to: end) }
        let state = load(), order = state["answeredOrder"] as? [String] ?? []
        let keys = Set((state["answered"] as? [String: Bool] ?? [:]).keys)
        let answered = keys.subtracting(order).sorted() + order.filter(keys.contains)  // older answers first, latest last
        let settings = settingsNow()
        let input = Suggestions.Input(
            samples: dayLogger.weekSamples(end: end), meetings: meetings(on: Set(days.map(dayKey))),
            chats: days.flatMap { WhatsAppActivityLogger.readLog(file: "chats", for: $0) },
            bot: days.flatMap { WhatsAppActivityLogger.readLog(file: "bot", for: $0) },
            edits: edits(since: days.last.map { Calendar.current.startOfDay(for: $0) } ?? end, kinds: ["meeting", "notes"]).map(\.text),
            erp: days.reversed().flatMap { d in ERP.tasksTouched(on: d).map { (day: dayKey(d), name: $0.name, project: $0.project) } },
            settings: settings, declined: answered)
        let context = [dayLogger.roleGuidance(), NikxelSettings.userContextBlock, NikxelSettings.languageInstruction].filter { !$0.isEmpty }.joined(separator: "\n\n")
        let reply: String
        do {
            reply = try agent.runPrompt(Suggestions.prompt(digest: Suggestions.digest(input), context: context), kind: "weekly-suggestions")
        } catch {
            cblog("Learning: weekly suggestions failed: \(error)")
            return ""
        }
        let items = Suggestions.parse(reply, settings: settings, answered: Set(answered))
        var advice: [String] = [], queued: [[String: Any]] = []
        for item in items {
            switch item {
            case let .advice(text, evidence): advice.append("- \(text)\(evidence.isEmpty ? "" : " — \(evidence)")")
            case let .offer(action, params, line, evidence):
                queued.append(["action": action, "params": params, "line": line, "evidence": evidence, "at": Date().timeIntervalSince1970])
            }
        }
        let ideas = advice.isEmpty ? "" : "## Ideas for you\n" + advice.joined(separator: "\n") + "\n"
        update { $0["queued"] = queued; $0["suggestedIdeas"] = ideas }
        cblog("Learning: weekly suggestions \(weekKey): \(advice.count) advice, \(queued.count) offers")
        return ideas
    }

    /// The weekly review's offers, one a day: older than 14 days, answered, or no longer changing anything drops out first.
    private static func offerQueued(_ dayLogger: DayLogger) {
        let now = Date().timeIntervalSince1970, settings = settingsNow(), today = dayKey(Date())
        var next: [String: Any]?
        update { s in  // filter and take the head in one go, so a weekly run's fresh queue is never overwritten by a stale one
            let answered = Set((s["answered"] as? [String: Bool] ?? [:]).keys)
            var live = (s["queued"] as? [[String: Any]] ?? []).filter { q in
                guard let at = q["at"] as? TimeInterval, now - at < 14 * 86_400 else { return false }
                // Through `parse` again so the same rules decide: valid, unanswered, still changing something.
                guard let data = try? JSONSerialization.data(withJSONObject: ["items": [q.merging(["kind": "offer"]) { a, _ in a }]]) else { return false }
                return !Suggestions.parse(String(decoding: data, as: UTF8.self), settings: settings, answered: answered).isEmpty
            }
            if s["askedDay"] as? String != today, !live.isEmpty { next = live.removeFirst() }
            s["queued"] = live
        }
        guard let q = next, let action = q["action"] as? String, let params = q["params"] as? [String: String],
              let line = q["line"] as? String else { return }
        let evidence = q["evidence"] as? String ?? ""
        let asked = offer(key: Suggestions.key(action: action, params: params), title: "An idea for your week",
                          line: evidence.isEmpty ? line : "\(line) (\(evidence))") { apply(action, params, dayLogger) }
        if !asked { update { $0["queued"] = [q] + ($0["queued"] as? [[String: Any]] ?? []) } }  // something else asked first: back in line
    }

    /// What a yes to a weekly offer does, per catalogue action.
    private static func apply(_ action: String, _ p: [String: String], _ dayLogger: DayLogger) {
        switch action {
        case "summaryTime":
            guard let m = Int(p["minutes"] ?? "") else { return }
            NikxelSettings.summaryMinutes = m
            DispatchQueue.main.async { dayLogger.reschedule() }
        case "autoRecordCalls": NikxelSettings.autoRecordCalls = true
        case "waDraftOnly": NikxelSettings.waDraftOnly = true
        case "waChatTasks": NikxelSettings.waChatTasks = true
        case "waQuietHours":
            guard let f = Int(p["from"] ?? ""), let t = Int(p["to"] ?? "") else { return }
            NikxelSettings.waQuietHours = true; NikxelSettings.waQuietFrom = f; NikxelSettings.waQuietTo = t
        case "summaryTemplate":
            guard let n = p["name"] else { return }
            NikxelSettings.summaryTemplate = n
            DispatchQueue.main.async { (NSApp.delegate as? NikxelAppDelegate)?.rebuildTemplateMenu() }
        case "summaryRule": if let t = p["text"] { addRule(t) }
        default: cblog("Learning: unknown weekly action \(action)")
        }
    }
}
