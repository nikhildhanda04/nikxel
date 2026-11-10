// Runnable check for UsageLog -- per-kind totals and the daily average.
//   swiftc -parse-as-library -o /tmp/cul src/UsageLog.swift check_usage_log.swift && /tmp/cul
import Foundation

@main struct Check {
    static func main() {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("nikxel-usage-\(ProcessInfo.processInfo.processIdentifier)")
        defer { try? FileManager.default.removeItem(at: dir) }
        var c = DateComponents(); c.year = 2026; c.month = 11; c.day = 10; c.hour = 12
        let now = Calendar.current.date(from: c)!
        let day = { (n: Int) in Calendar.current.date(byAdding: .day, value: -n, to: now)! }
        func run(_ tokens: Int, _ cost: Double) -> Data {
            try! JSONSerialization.data(withJSONObject: [
                "result": "hi", "total_cost_usd": cost,
                "usage": ["input_tokens": 2, "output_tokens": 8,
                          "cache_read_input_tokens": tokens - 10, "cache_creation_input_tokens": 0]])
        }

        UsageLog.record(run(1000, 0.01), kind: "whatsapp", in: dir, now: now)
        UsageLog.record(run(2000, 0.02), kind: "whatsapp", in: dir, now: now)
        UsageLog.record(run(5000, 0.10), kind: "daily-summary", in: dir, now: now)
        UsageLog.record(Data("not json".utf8), kind: "whatsapp", in: dir, now: now)
        let t = UsageLog.totals(for: now, in: dir)
        assert(t["whatsapp"] == UsageLog.Totals(calls: 2, tokens: 3000, cost: 0.03), "\(t)")
        assert(t["daily-summary"]?.calls == 1)

        // Average skips empty days and excludes today: days 1 and 3 only.
        UsageLog.record(run(4000, 0.04), kind: "whatsapp", in: dir, now: day(1))
        UsageLog.record(run(2000, 0.02), kind: "whatsapp", in: dir, now: day(3))
        let (avg, n) = UsageLog.dailyAverage(days: 7, in: dir, now: now)
        assert(n == 2 && avg.tokens == 3000 && avg.calls == 1 && abs(avg.cost - 0.03) < 1e-9, "\(avg) \(n)")
        assert(UsageLog.dailyAverage(days: 7, in: dir.appendingPathComponent("none"), now: now).days == 0)
        assert(UsageLog.line(UsageLog.Totals(calls: 1, tokens: 37400, cost: 0.041)) == "$0.041 · 37k tokens · 1 call")
        print("check_usage_log: ok")
    }
}
