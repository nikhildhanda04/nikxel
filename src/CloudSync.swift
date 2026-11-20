import Foundation
import CryptoKit

/// Pairs this Mac with the org dashboard and pushes the derived work summary.
/// DATA BOUNDARY: the only thing that ever leaves is {kind, date, items:[{id,what,minutes}]}
/// plus the device token as bearer. Never logs, twin, erp.md, raw activity or email.
/// Mirrors cloudSync.ts.
enum CloudSync {
    /// Dev default; set NIKXEL_BACKEND to point elsewhere. No production URL yet.
    static var backendBase: String { ProcessInfo.processInfo.environment["NIKXEL_BACKEND"] ?? "http://localhost:3001" }
    private static var tokenFile: String { NSHomeDirectory() + "/.nikxel/cloud-token" }

    static var token: String? {
        let t = (try? String(contentsOfFile: tokenFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (t?.isEmpty ?? true) ? nil : t
    }

    /// Blocking POST (callers are off the main thread). Returns the 2xx body, nil on any failure.
    typealias Poster = (_ path: String, _ body: [String: Any], _ bearer: String?) -> Data?

    static let httpPost: Poster = { path, body, bearer in
        guard let url = URL(string: backendBase + path),
              let data = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let b = bearer { req.setValue("Bearer \(b)", forHTTPHeaderField: "Authorization") }
        req.httpBody = data
        var out: Data?
        let sem = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: req) { d, r, _ in
            if let h = r as? HTTPURLResponse, (200..<300).contains(h.statusCode) { out = d }
            sem.signal()
        }.resume()
        sem.wait()
        return out
    }

    @discardableResult
    static func pair(_ code: String, post: Poster = httpPost) -> Bool {
        let c = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !c.isEmpty, let data = post("/api/pair", ["code": c], nil),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tok = obj["deviceToken"] as? String, !tok.isEmpty else { return false }
        try? FileManager.default.createDirectory(atPath: (tokenFile as NSString).deletingLastPathComponent,
                                                 withIntermediateDirectories: true)
        guard FileManager.default.createFile(atPath: tokenFile, contents: Data(tok.utf8),
                                             attributes: [.posixPermissions: 0o600]) else { return false }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tokenFile)
        return true
    }

    /// No token → no-op (poster never called). Network failure is silent.
    static func pushDaily(summary: String, day: String, post: Poster = httpPost) {
        guard let tok = token else { return }
        let items = workItems(fromDailySummary: summary).map { ["id": $0.id, "what": $0.what, "minutes": $0.minutes] as [String: Any] }
        guard !items.isEmpty else { return }
        _ = post("/api/summaries", ["kind": "work", "date": day, "items": items], tok)
    }

    struct WorkItem: Equatable { let id: String; let what: String; let minutes: Int }

    /// Top-level bullets of "## What you worked on". Minutes from "1h 30m" / "45 min" / "2h" (0 if none).
    static func workItems(fromDailySummary md: String) -> [WorkItem] {
        var inSection = false
        var out: [WorkItem] = []
        let dur = try! NSRegularExpression(pattern: #"\b(?:(\d+)\s*h(?:ours?|rs?)?(?:\s*(\d+)\s*m(?:in(?:ute)?s?)?)?|(\d+)\s*m(?:in(?:ute)?s?)?)\b"#, options: .caseInsensitive)
        for line in md.components(separatedBy: "\n") {
            if line.hasPrefix("## ") { inSection = line.lowercased().contains("what you worked on"); continue }
            guard inSection, line.hasPrefix("- ") || line.hasPrefix("* ") else { continue }
            var text = String(line.dropFirst(2)).replacingOccurrences(of: "**", with: "")
            var minutes = 0
            let ns = text as NSString
            if let m = dur.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) {
                func g(_ i: Int) -> Int { m.range(at: i).location == NSNotFound ? 0 : Int(ns.substring(with: m.range(at: i))) ?? 0 }
                minutes = g(1) * 60 + g(2) + g(3)
                text = ns.replacingCharacters(in: m.range, with: "")
            }
            let what = text.replacingOccurrences(of: "~", with: "").replacingOccurrences(of: "()", with: "")
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: CharacterSet(charactersIn: " —-–:,;"))
            if what.count < 3 || what.lowercased().hasPrefix("none") || what.lowercased().hasPrefix("nothing") { continue }
            let norm = what.lowercased()
            let id = SHA256.hash(data: Data(norm.utf8)).map { String(format: "%02x", $0) }.joined().prefix(12)
            out.append(WorkItem(id: String(id), what: what, minutes: minutes))
        }
        return out
    }
}
