import Cocoa
import AVFoundation

/// "Copy Logs" in the menu: one plain-text report for a user to paste into a
/// chat when something breaks, instead of being walked through folders.
/// Tails only -- the logs hold chat and meeting text, so it sends the least
/// that still shows what went wrong.
enum SupportLogs {
    static func report() -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let nx = home.appendingPathComponent(".nikxel")
        var out = "Nikxel logs — \(Date())\n"
        out += "macOS \(ProcessInfo.processInfo.operatingSystemVersionString)\n"
        out += "App: \(Bundle.main.bundlePath)\n"
        if let repo = Updater.repoRoot {
            out += "Commit: \(run("/usr/bin/git", ["-C", repo.path, "log", "--oneline", "-1"]))"
        }
        out += "Signature: " + run("/usr/bin/codesign", ["-dvv", Bundle.main.bundlePath])
            .components(separatedBy: "\n").filter { $0.hasPrefix("Authority=") || $0.hasPrefix("Signature=") }
            .prefix(1).joined() + "\n"
        out += "Permissions: accessibility=\(AXIsProcessTrusted()) screen=\(CGPreflightScreenCaptureAccess()) "
            + "mic=\(AVCaptureDevice.authorizationStatus(for: .audio) == .authorized)\n"
        out += "Memory: " + memory() + "\n"

        out += section("chatbot.log", tail(nx.appendingPathComponent("chatbot.log"), 60))
        out += section("debug.log", tail(nx.appendingPathComponent("debug.log"), 40))
        out += section("update.log", tail(nx.appendingPathComponent("update.log"), 30))

        // Newest summary run: its stderr/stdout say why notes failed.
        let ws = nx.appendingPathComponent("momworkspace")
        if let runs = try? FileManager.default.contentsOfDirectory(atPath: ws.path),
           let last = runs.filter({ $0.first?.isNumber == true }).sorted().last {
            let dir = ws.appendingPathComponent(last)
            out += section("summary run \(last) stderr", tail(dir.appendingPathComponent("last_stderr.log"), 20))
            out += section("summary run \(last) stdout", tail(dir.appendingPathComponent("last_stdout.log"), 10))
        }
        out += section("last crash", lastCrash(home))
        return out
    }

    /// RSS of Nikxel and of what it starts, so "it uses 1 GB" says which part.
    private static func memory() -> String {
        var mb: [String: Int] = [:]
        let me = Bundle.main.executablePath ?? "Nikxel"
        for line in run("/bin/ps", ["-axo", "rss=,command="]).split(separator: "\n") {
            let parts = line.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 1)
            guard parts.count == 2, let kb = Int(parts[0]) else { continue }
            let cmd = String(parts[1])
            let key = cmd.hasPrefix(me) ? "nikxel"
                : cmd.contains(ChromeBot.profileDir) ? "whatsapp-browser"
                : cmd.contains("whisper") ? "whisper" : nil
            if let key { mb[key, default: 0] += kb / 1024 }
        }
        return mb.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)MB" }.joined(separator: " ")
    }

    private static func section(_ name: String, _ body: String) -> String {
        body.isEmpty ? "" : "\n--- \(name) ---\n\(body)\n"
    }

    private static func tail(_ url: URL, _ n: Int) -> String {
        guard let s = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return s.components(separatedBy: "\n").suffix(n).joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Newest Nikxel .ips, reduced to what names the bug: the exception and
    /// the crashing thread's top frames. The full report is ~50 KB of noise.
    private static func lastCrash(_ home: URL) -> String {
        let dir = home.appendingPathComponent("Library/Logs/DiagnosticReports")
        guard let name = (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?
                .filter({ $0.hasPrefix("Nikxel") && $0.hasSuffix(".ips") }).sorted().last,
              let raw = try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8),
              let nl = raw.firstIndex(of: "\n"),
              let obj = (try? JSONSerialization.jsonObject(with: Data(raw[nl...].utf8))) as? [String: Any]
        else { return "" }
        func symbols(_ frames: [[String: Any]]?) -> String {
            (frames ?? []).prefix(12).compactMap { $0["symbol"] as? String }.joined(separator: "\n  ")
        }
        var s = "\(name)\n\(obj["captureTime"] ?? "")\n"
        if let e = obj["exception"] as? [String: Any] { s += "exception: \(e["type"] ?? "") \(e["signal"] ?? "")\n" }
        if let bt = obj["lastExceptionBacktrace"] as? [[String: Any]] { s += "exception backtrace:\n  \(symbols(bt))\n" }
        if let threads = obj["threads"] as? [[String: Any]],
           let t = threads.first(where: { $0["triggered"] as? Bool == true }) {
            s += "crashed thread:\n  \(symbols(t["frames"] as? [[String: Any]]))\n"
        }
        return s
    }

    private static func run(_ path: String, _ args: [String]) -> String {
        let p = Process(); p.launchPath = path; p.arguments = args
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
        guard (try? p.run()) != nil else { return "" }
        let d = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        return String(data: d, encoding: .utf8) ?? ""
    }
}
