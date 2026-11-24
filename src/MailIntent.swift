import Foundation

/// The chat's mail decisions, kept free of networking so checks/check_mail_intent.swift
/// can run them: does a message concern mail, is it "send it", what the router model
/// asked for, and the RFC 2822 text a draft is made of. Same as
/// windows/src/main/google/mailIntent.ts.

struct MailDraft: Equatable {
    var to: String
    var cc: String
    var subject: String
    var body: String
    var replyTo: String?   // Gmail message id being answered
}

struct MailMessage {
    var id = "", threadId = "", from = "", to = "", subject = "", date = "", snippet = "", body = ""
    var messageId = ""      // RFC Message-ID header, for In-Reply-To
    var references = ""
}

enum MailLabelOp: String { case archive, read, unread, star }

enum MailAction {
    case answer
    case search(String)
    case draft(MailDraft)
    case label(ids: [String], op: MailLabelOp)
}

enum MailIntent {
    static func looksLikeMail(_ text: String) -> Bool {
        text.range(of: #"\b(e-?mails?|mails?|inbox|gmail|repl(y|ies)|draft|archive|unread|starred?|cc|subject)\b"#,
                   options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// The whole message is a go-ahead to send ("send it", "ok, send it now.").
    /// Matched here, never by the model: mail only goes out when the user says so.
    static func isSendCommand(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).range(
            of: #"^((ok(ay)?|yes|yep|sure|great|looks good)[,.!]?\s+)*send(\s+(it|that|this|the\s+(draft|mail|email)))?(\s+now)?[.!]*$"#,
            options: [.regularExpression, .caseInsensitive]) != nil
    }

    static func routerPrompt(request: String, context: String, history: [(q: String, a: String)], today: Date) -> String {
        let day = ISO8601DateFormatter.string(from: today, timeZone: .current, formatOptions: [.withFullDate])
        var p = """
        You are the user's desk avatar deciding what to do with a message about their email. Today is \(day).
        The notes below include "### mail" lines like "- [<id>] sender · subject · date: preview".
        Reply with ONE JSON object and nothing else:
        {"action":"answer"} — the notes already answer it.
        {"action":"search","query":"<Gmail search, e.g. from:piyush invoice newer_than:60d>"} — it needs mail not in the notes.
        {"action":"draft","to":"<email>","cc":"","subject":"...","body":"...","replyTo":"<id or empty>"} — the user wants an email written. \
        For a reply set replyTo to the id being answered and leave to as the sender's address. Write the body in the user's voice, \
        plain text, no placeholders like [Name]; sign off with the user's first name if the notes give it.
        {"action":"label","ids":["<id>",...],"op":"archive|read|unread|star"} — archive, mark read/unread or star emails from the notes.

        NOTES:
        \(context)

        """
        for h in history { p += "\nUser: \(h.q)\nYou: \(h.a)\n" }
        return p + "\nUser: \(request)"
    }

    static func parseAction(_ reply: String) -> MailAction {
        guard let start = reply.firstIndex(of: "{"), let end = reply.lastIndex(of: "}"), start < end,
              let obj = (try? JSONSerialization.jsonObject(with: Data(reply[start...end].utf8))) as? [String: Any],
              let action = obj["action"] as? String else { return .answer }
        let s = { (k: String) in (obj[k] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        switch action {
        case "search" where !s("query").isEmpty:
            return .search(s("query"))
        case "draft" where !s("body").isEmpty:
            return .draft(MailDraft(to: s("to"), cc: s("cc"), subject: s("subject"), body: s("body"),
                                    replyTo: s("replyTo").isEmpty ? nil : s("replyTo")))
        case "label":
            guard let op = MailLabelOp(rawValue: s("op")), let ids = obj["ids"] as? [String], !ids.isEmpty else { return .answer }
            return .label(ids: ids, op: op)
        default:
            return .answer
        }
    }

    /// A draft as Gmail's `raw`: RFC 2822, UTF-8 body in base64, the whole thing base64url.
    static func rawMessage(_ d: MailDraft, inReplyTo: String?, references: String?) -> String {
        func header(_ v: String) -> String {
            v.allSatisfy(\.isASCII) ? v : "=?UTF-8?B?\(Data(v.utf8).base64EncodedString())?="
        }
        var lines = ["To: \(d.to)"]
        if !d.cc.isEmpty { lines.append("Cc: \(d.cc)") }
        lines.append("Subject: \(header(d.subject))")
        if let r = inReplyTo, !r.isEmpty {
            lines.append("In-Reply-To: \(r)")
            lines.append("References: \([references ?? "", r].filter { !$0.isEmpty }.joined(separator: " "))")
        }
        lines += ["MIME-Version: 1.0", "Content-Type: text/plain; charset=UTF-8", "Content-Transfer-Encoding: base64", "",
                  Data(d.body.utf8).base64EncodedString(options: .lineLength76Characters)]
        return Data(lines.joined(separator: "\r\n").utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func contextBlock(unread: [MailMessage], recent: [MailMessage]) -> String {
        func line(_ m: MailMessage) -> String { "- [\(m.id)] \(m.from) · \(m.subject) · \(m.date): \(m.snippet.prefix(160))" }
        var parts: [String] = []
        if !unread.isEmpty { parts.append("Unread in the inbox:\n" + unread.map(line).joined(separator: "\n")) }
        if !recent.isEmpty { parts.append("Latest in the inbox (newest first):\n" + recent.map(line).joined(separator: "\n")) }
        return parts.isEmpty ? "" : "### mail\n" + parts.joined(separator: "\n\n")
    }

    static func searchBlock(query: String, _ ms: [MailMessage]) -> String {
        "### mail search: \(query)\n" + (ms.isEmpty ? "(no matches)" : ms.map {
            "[\($0.id)] From \($0.from) to \($0.to) · \($0.subject) · \($0.date)\n\($0.body.isEmpty ? $0.snippet : $0.body)"
        }.joined(separator: "\n\n"))
    }
}
