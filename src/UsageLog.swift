import Foundation

/// Tokens and dollars spent on Claude Code runs, one JSON line per run in
/// ~/.nikxel/usage/YYYY-MM-DD.jsonl. Read back for the menu bar's usage line.
/// Only Claude Code reports cost in its output; opencode/codex runs aren't logged.
enum UsageLog {
    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".nikxel/usage", isDirectory: true)
    }

    struct Totals: Equatable {
        var calls = 0
        var tokens = 0
        var cost = 0.0
    }

    /// Records one `claude -p --output-format json` result. Anything that
    /// isn't that shape is ignored rather than logged as a zero.
    static func record(_ claudeJSON: Data, kind: String, in dir: URL = directory, now: Date = Date()) {
        guard let obj = try? JSONSerialization.jsonObject(with: claudeJSON) as? [String: Any],
              let usage = obj["usage"] as? [String: Any] else { return }
        let tokens = ["input_tokens", "output_tokens", "cache_read_input_tokens", "cache_creation_input_tokens"]
            .reduce(0) { $0 + (usage[$1] as? Int ?? 0) }
        let entry: [String: Any] = [
            "t": now.timeIntervalSince1970,
            "kind": kind,
            "model": (obj["modelUsage"] as? [String: Any])?.keys.sorted().joined(separator: ",") ?? "",
            "tokens": tokens,
            "cost": obj["total_cost_usd"] as? Double ?? 0,
            "ms": obj["duration_ms"] as? Int ?? 0,
        ]
        guard var line = try? JSONSerialization.data(withJSONObject: entry) else { return }
        line.append(0x0A)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(dayKey(now)).jsonl")
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(line); try? h.close()
        } else {
            try? line.write(to: url)
        }
    }

    /// Per-kind totals for one day ("whatsapp", "daily-summary", "meeting", "notes").
    static func totals(for date: Date, in dir: URL = directory) -> [String: Totals] {
        guard let content = try? String(contentsOf: dir.appendingPathComponent("\(dayKey(date)).jsonl"),
                                        encoding: .utf8) else { return [:] }
        var out: [String: Totals] = [:]
        for line in content.split(separator: "\n") {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let kind = obj["kind"] as? String else { continue }
            out[kind, default: Totals()].calls += 1
            out[kind, default: Totals()].tokens += obj["tokens"] as? Int ?? 0
            out[kind, default: Totals()].cost += obj["cost"] as? Double ?? 0
        }
        return out
    }

    /// Average per day over the `days` days before `now`, counting only days
    /// with any usage -- a week the Mac was off shouldn't drag the average to zero.
    static func dailyAverage(days: Int = 7, in dir: URL = directory, now: Date = Date()) -> (Totals, days: Int) {
        var sum = Totals(), counted = 0
        for offset in 1...days {
            guard let d = Calendar.current.date(byAdding: .day, value: -offset, to: now) else { continue }
            let day = totals(for: d, in: dir).values
            guard !day.isEmpty else { continue }
            counted += 1
            for t in day { sum.calls += t.calls; sum.tokens += t.tokens; sum.cost += t.cost }
        }
        guard counted > 0 else { return (Totals(), 0) }
        return (Totals(calls: sum.calls / counted, tokens: sum.tokens / counted,
                       cost: sum.cost / Double(counted)), counted)
    }

    /// "$0.041 · 37k tokens · 12 calls"
    static func line(_ t: Totals) -> String {
        let tok = t.tokens >= 1000 ? "\(t.tokens / 1000)k" : "\(t.tokens)"
        return String(format: "$%.3f", t.cost) + " · \(tok) tokens · \(t.calls) call\(t.calls == 1 ? "" : "s")"
    }

    private static func dayKey(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        return fmt.string(from: date)
    }
}
