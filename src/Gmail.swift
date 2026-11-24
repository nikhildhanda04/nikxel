import Foundation

/// Gmail over REST with the shared Google sign-in, for the avatar chat: the inbox at
/// chat open, a search when the question needs older mail, drafts, sending a draft the
/// user said to send, and archive/read/star. Nothing is stored. Calls block, so run them
/// off the main thread (the chat already does). Same as windows/src/main/google/gmail.ts.
enum Gmail {
    static let scope = "https://www.googleapis.com/auth/gmail.modify"
    private static let base = "https://gmail.googleapis.com/gmail/v1/users/me"

    static var isReady: Bool { GoogleAuth.shared.isAuthorized && GoogleAuth.shared.hasScope(scope) }

    private static func token() -> String? {
        let sema = DispatchSemaphore(value: 0)
        var t: String?
        GoogleAuth.shared.withAccessToken { t = $0; sema.signal() }
        _ = sema.wait(timeout: .now() + 15)
        return t
    }

    /// JSON in, JSON out; nil on any failure (logged).
    private static func call(_ method: String, _ path: String, body: [String: Any]? = nil) -> [String: Any]? {
        guard let tok = token(), let url = URL(string: base + path) else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.httpMethod = method
        req.setValue("Bearer \(tok)", forHTTPHeaderField: "Authorization")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        let sema = DispatchSemaphore(value: 0)
        var out: [String: Any]?
        URLSession.shared.dataTask(with: req) { data, resp, _ in
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if (200..<300).contains(code) {
                out = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
            } else {
                cblog("Gmail: \(method) \(path.prefix(60)) -> \(code) \(data.map { String(decoding: $0.prefix(200), as: UTF8.self) } ?? "")")
            }
            sema.signal()
        }.resume()
        _ = sema.wait(timeout: .now() + 25)
        return out
    }

    private static func q(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&+=?"))) ?? s }

    private static func ids(_ query: String, max: Int) -> [String] {
        (call("GET", "/messages?maxResults=\(max)&q=\(q(query))")?["messages"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
    }

    /// Several gets at once; a 30-message inbox one by one is ~10 s.
    private static func fetch(_ ids: [String], full: Bool) -> [MailMessage] {
        var out = [MailMessage?](repeating: nil, count: ids.count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: ids.count) { i in
            let m = message(ids[i], full: full)
            lock.lock(); out[i] = m; lock.unlock()
        }
        return out.compactMap { $0 }
    }

    static func message(_ id: String, full: Bool = false) -> MailMessage? {
        let fmt = full ? "format=full"
            : "format=metadata&" + ["From", "To", "Subject", "Date", "Message-ID", "References"].map { "metadataHeaders=\($0)" }.joined(separator: "&")
        guard let m = call("GET", "/messages/\(q(id))?\(fmt)") else { return nil }
        let payload = m["payload"] as? [String: Any] ?? [:]
        var h: [String: String] = [:]
        for x in payload["headers"] as? [[String: Any]] ?? [] {
            if let n = x["name"] as? String, let v = x["value"] as? String { h[n.lowercased()] = v }
        }
        return MailMessage(id: id, threadId: m["threadId"] as? String ?? "", from: h["from"] ?? "", to: h["to"] ?? "",
                           subject: h["subject"] ?? "(no subject)", date: h["date"] ?? "",
                           snippet: decodeEntities(m["snippet"] as? String ?? ""),
                           body: full ? trimmed(text(payload)) : "", messageId: h["message-id"] ?? "", references: h["references"] ?? "")
    }

    static func inbox() -> (unread: [MailMessage], recent: [MailMessage]) {
        let unread = ids("in:inbox is:unread", max: 20)
        let recent = ids("in:inbox", max: 30).filter { !unread.contains($0) }
        let all = fetch(unread + recent, full: false)
        return (all.filter { unread.contains($0.id) }, all.filter { !unread.contains($0.id) })
    }

    static func search(_ query: String) -> [MailMessage] { fetch(ids(query, max: 8), full: true) }

    /// Returns the draft id and its message id (the one Gmail's compose URL takes).
    static func createDraft(_ d: MailDraft, replyTo: MailMessage?) -> (draftId: String, messageId: String)? {
        var msg: [String: Any] = ["raw": MailIntent.rawMessage(d, inReplyTo: replyTo?.messageId, references: replyTo?.references)]
        if let t = replyTo?.threadId, !t.isEmpty { msg["threadId"] = t }
        guard let r = call("POST", "/drafts", body: ["message": msg]), let id = r["id"] as? String else { return nil }
        return (id, (r["message"] as? [String: Any])?["id"] as? String ?? "")
    }

    static func sendDraft(_ id: String) -> Bool { call("POST", "/drafts/send", body: ["id": id]) != nil }

    static func modify(_ ids: [String], _ op: MailLabelOp) -> Bool {
        let (add, remove): ([String], [String]) = switch op {
        case .archive: ([], ["INBOX"])
        case .read: ([], ["UNREAD"])
        case .unread: (["UNREAD"], [])
        case .star: (["STARRED"], [])
        }
        return call("POST", "/messages/batchModify", body: ["ids": ids, "addLabelIds": add, "removeLabelIds": remove]) != nil
    }

    // MARK: - Body text

    private static func text(_ part: [String: Any]) -> String {
        let mime = part["mimeType"] as? String ?? ""
        let parts = part["parts"] as? [[String: Any]] ?? []
        if parts.isEmpty {
            guard let data = (part["body"] as? [String: Any])?["data"] as? String else { return "" }
            var b64 = data.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            while b64.count % 4 != 0 { b64 += "=" }
            let s = Data(base64Encoded: b64).map { String(decoding: $0, as: UTF8.self) } ?? ""
            return mime == "text/html" ? stripHTML(s) : (mime.hasPrefix("text/") ? s : "")
        }
        // Plain text over HTML when a message has both.
        if let plain = parts.first(where: { $0["mimeType"] as? String == "text/plain" }) { return text(plain) }
        return parts.map(text).first { !$0.isEmpty } ?? ""
    }

    private static func stripHTML(_ s: String) -> String {
        decodeEntities(s.replacingOccurrences(of: #"(?is)<(style|script)[^>]*>.*?</\1>"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)<br\s*/?>|</p>|</div>"#, with: "\n", options: .regularExpression)
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression))
    }

    private static func decodeEntities(_ s: String) -> String {
        s.replacingOccurrences(of: "&nbsp;", with: " ").replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&#39;", with: "'")
    }

    /// Up to the quoted history ("On … wrote:" / "> "), blank runs squeezed, ≤3000 chars.
    private static func trimmed(_ s: String) -> String {
        var out: [String] = []
        for l in s.components(separatedBy: .newlines) {
            if l.range(of: #"^On .+wrote:\s*$"#, options: .regularExpression) != nil || l.hasPrefix(">") { break }
            out.append(l.trimmingCharacters(in: .whitespaces))
        }
        return String(out.joined(separator: "\n").replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines).prefix(3000))
    }
}
