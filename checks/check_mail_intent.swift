import Foundation

// swiftc src/MailIntent.swift checks/check_mail_intent.swift -o /tmp/cmi && /tmp/cmi
@main enum CheckMailIntent {
    static func main() {
        var fails = 0
        func check(_ ok: Bool, _ what: String) { if !ok { fails += 1; print("FAIL: \(what)") } }

        check(MailIntent.looksLikeMail("any mail from Piyush?"), "mail question")
        check(MailIntent.looksLikeMail("reply to the invoice email"), "reply")
        check(!MailIntent.looksLikeMail("what did I do today"), "not mail")
        check(MailIntent.isSendCommand("send it"), "send it")
        check(MailIntent.isSendCommand("Ok, send it now."), "ok send it now")
        check(MailIntent.isSendCommand("yes send the draft"), "send the draft")
        check(!MailIntent.isSendCommand("send Piyush the invoice"), "not a send command")

        if case .search(let q) = MailIntent.parseAction("```json\n{\"action\":\"search\",\"query\":\"from:piyush\"}\n```") {
            check(q == "from:piyush", "search query")
        } else { check(false, "fenced search") }
        if case .answer = MailIntent.parseAction("Sure! Here you go.") {} else { check(false, "prose -> answer") }
        if case .draft(let d) = MailIntent.parseAction(#"{"action":"draft","to":"a@b.com","cc":"","subject":"Hi","body":"Hello","replyTo":"18c"}"#) {
            check(d.to == "a@b.com" && d.subject == "Hi" && d.body == "Hello" && d.replyTo == "18c", "draft fields")
        } else { check(false, "draft") }
        if case .label(let ids, let op) = MailIntent.parseAction(#"{"action":"label","ids":["1","2"],"op":"archive"}"#) {
            check(ids == ["1", "2"] && op == .archive, "label")
        } else { check(false, "label") }

        let raw = MailIntent.rawMessage(MailDraft(to: "a@b.com", cc: "", subject: "₹ invoice", body: "नमस्ते 👋", replyTo: nil),
                                        inReplyTo: "<x@y>", references: nil)
        var b64 = raw.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        let text = Data(base64Encoded: b64).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        check(text.contains("Subject: =?UTF-8?B?"), "subject encoded")
        check(text.contains("In-Reply-To: <x@y>") && text.contains("References: <x@y>"), "reply headers")
        let bodyB64 = text.components(separatedBy: "\r\n\r\n").last ?? ""
        check(Data(base64Encoded: bodyB64.replacingOccurrences(of: "\r\n", with: "")).flatMap { String(data: $0, encoding: .utf8) } == "नमस्ते 👋", "body round-trip")

        print(fails == 0 ? "ALL PASS" : "\(fails) FAILED")
        exit(fails == 0 ? 0 : 1)
    }
}
