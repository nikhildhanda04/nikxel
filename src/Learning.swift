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
        update { s in var a = s["answered"] as? [String: Bool] ?? [:]; a[key] = yes; s["answered"] = a }
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
            if offerSummaryTime(dayLogger) || offerAutoRecord() { return }
            offerRule(agent)
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
    private static func offerRule(_ agent: MOMGenerator) {
        let recent = edits(since: Date().addingTimeInterval(-30 * 86_400), kinds: ["meeting", "notes"])
        let reviewed = load()["reviewedEditsAt"] as? TimeInterval ?? 0
        guard recent.count >= 2, let newest = recent.map(\.t).max(), newest > reviewed else { return }
        update { $0["reviewedEditsAt"] = newest }
        let decided = (load()["answered"] as? [String: Bool] ?? [:]).keys.filter { $0.hasPrefix("rule:") }.map { String($0.dropFirst(5)) }
        guard let reply = try? agent.runPrompt(Habits.rulePrompt(edits: recent.map(\.text), decided: decided),
                                               kind: "learning-rule", claudeModel: "haiku"),
              let r = Habits.parseRule(reply) else { return }
        offer(key: "rule:" + r.rule, title: "Your meeting summaries",
              line: "You've asked me this \(r.times) times\(r.example.isEmpty ? "" : " (\"\(r.example)\")"). I'm thinking of always doing it in your meeting summaries: \(r.rule)") {
            let url = SummaryTemplates.activeURL
            let old = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            try? (old + (old.hasSuffix("\n") || old.isEmpty ? "" : "\n") + "\n# Added by Nikxel after you said yes (\(dayKey(Date()))):\n\(r.rule)\n")
                .write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
