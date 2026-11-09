import Foundation

/// LLM response generation.  Uses the existing MOMGenerator.openCode pipeline
/// but with a chat-personality prompt instead of a meeting-summary prompt.
class LLMResponder {
    private let momGenerator: MOMGenerator
    private let personalityPath: URL

    init(momGenerator: MOMGenerator) {
        self.momGenerator = momGenerator
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".nikxel", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.personalityPath = dir.appendingPathComponent("bot_personality.txt")
    }

    /// Load the bot personality from disk — or write the default.
    var personality: String {
        if let content = try? String(contentsOf: personalityPath, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), !content.isEmpty {
            return content
        }
        let name = NikxelSettings.userName
        let def = """
        You are \(name)'s friendly AI assistant. You're responding to WhatsApp messages \
        while \(name) is in a meeting. Be casual, warm, and helpful. Keep responses \
        concise (1-3 sentences). Be honest -- say you're \(name)'s assistant, don't \
        pretend to be \(name). If you don't know something, say so.
        """
        try? def.write(to: personalityPath, atomically: true, encoding: .utf8)
        return def
    }

    /// What came back from one reply pass: the message to send, and -- when the
    /// contact actually asked for something -- a task to file.
    struct Reply {
        let text: String
        /// Short imperative pulled out of the contact's message, e.g. "Send the
        /// deck to Priya by Friday". nil when they weren't asking for anything.
        let task: String?
    }

    /// Generate a reply for a contact based on their message preview and
    /// previous conversation history.
    func reply(for contact: String,
               messagePreview: String?,
               history: [(role: String, text: String)]) -> Reply? {
        let msgs = messagePreview != nil ? [messagePreview!] : []
        let prompt = buildPrompt(contact: contact, history: history, newMessages: msgs)
        do {
            let raw = try momGenerator.runPrompt(prompt)
            // Task marker first: cleanReply truncates to three sentences, which
            // would eat a trailing marker before it was ever read.
            let (body, task) = Self.extractTask(raw)
            guard let text = cleanReply(body) else { return nil }
            return Reply(text: text, task: task)
        } catch {
            cblog("LLMResponder: failed — \(error)")
            return nil
        }
    }

    /// Pulls `[[TASK: ...]]` markers out of a raw reply and hands back the
    /// message with them removed.
    ///
    /// A marker rather than a second LLM call: the agent is already reading the
    /// message to answer it, so asking for one extra line costs nothing. Only
    /// the first marker is kept -- one message is one ask, and a model that
    /// emits five has misunderstood the instruction.
    static func extractTask(_ raw: String) -> (body: String, task: String?) {
        var task: String?
        var body = raw
        while let open = body.range(of: "[[TASK:"),
              let close = body.range(of: "]]", range: open.upperBound..<body.endIndex) {
            let inner = body[open.upperBound..<close.lowerBound]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if task == nil, !inner.isEmpty, inner.lowercased() != "none" {
                task = inner
            }
            body.removeSubrange(open.lowerBound..<close.upperBound)
        }
        return (body.trimmingCharacters(in: .whitespacesAndNewlines), task)
    }

    private func buildPrompt(contact: String,
                             history: [(role: String, text: String)],
                             newMessages: [String]) -> String {
        let trusted = WAContactLists.contains(.trusted, contact: contact)
        var p = personality + "\n\n"
        p += recentContextBlock(trusted: trusted)
        p += "Contact: \(contact)\(trusted ? " (one of \(NikxelSettings.userName)'s own people)" : "")\n"
        if !history.isEmpty {
            p += "\nConversation so far:\n"
            for (role, text) in history.suffix(6) {
                p += "- \(role): \(text)\n"
            }
        }
        p += "\nTheir latest message(s):\n"
        for msg in newMessages { p += "- \(msg)\n" }
        p += "\nRespond in character. Keep it under 3 sentences. No markdown. No code blocks.\n"
        if NikxelSettings.waChatTasks {
            p += """

            If -- and only if -- their message contains a concrete thing \
            \(NikxelSettings.userName) has to DO (a request, a deadline, \
            something to send or check), add one final line in exactly this \
            form, after your reply:
            [[TASK: <short imperative, under 12 words>]]
            Keep any date or name they gave inside the title ("Send the deck to \
            Priya by Friday"). The line is stripped before the message is sent \
            and the contact never sees it. If they were only chatting, asking \
            how you are, or sharing news, add nothing -- an empty inbox is worth \
            more than an invented task.

            """
        }
        p += NikxelSettings.languageInstruction
        if NikxelSettings.language.lowercased() == "auto" {
            p += " Match the contact's own language/tone — if they write in Hindi or Hinglish, reply the same way; if they write in English, reply in English."
        }
        return p
    }

    /// Everything the bot knows about what the user is up to: what they are
    /// doing right now, how today has gone so far, and the last few end-of-day
    /// summaries. Lets it answer "any update on X?" instead of "I'm not sure,
    /// I'll pass it on".
    ///
    /// These are detailed -- repos and commits, window titles, which apps were
    /// used, who else was messaged and called. The bot replies automatically to
    /// whoever happens to write, including people who should not learn any of
    /// that, so the block is wrapped in an explicit non-disclosure rule.
    /// Context for understanding the question; not material to volunteer.
    ///
    /// Not private: check_bot_memory.swift prints this block and feeds it to a
    /// real agent to confirm the non-disclosure rules actually hold.
    func recentContextBlock(trusted: Bool = false) -> String {
        let days = NikxelSettings.botMemoryDays
        let summaries = DayLogger.recentSummaries(days: days)
        let live = NikxelSettings.waWorkContext
            ? (DayLogger.current?.liveContext(inMeeting: MeetingDetector.shared.isInMeeting) ?? "")
            : ""
        guard !summaries.isEmpty || !live.isEmpty else { return "" }

        // Two rule sets over the same material. The strict one is the default
        // because the bot answers whoever happens to write; the relaxed one
        // applies only to names the user put on the trusted list by hand.
        var block = trusted
        ? """
        BACKGROUND -- \(NikxelSettings.userName)'s own notes on what they are \
        doing. This contact is on their trusted list, so you may answer from \
        this directly: name the project, say what was built or committed, say \
        what the meeting was about.

        Still holds, even here:
        - Don't mention these notes exist, and don't say you have access to a log. \
        Speak as someone who simply knows what they're up to.
        - Don't pass on what OTHER people said in confidence, or details about \
        third parties and their clients. Their own work, yes; everyone else's, no.
        - Don't invent. If it isn't in here, say you're not sure and they'll \
        confirm themselves.


        """
        : """
        BACKGROUND -- \(NikxelSettings.userName)'s own notes on what they are \
        doing. This is private. Use it only to understand what the contact is \
        asking about and to answer naturally when they raise something you \
        recognise.

        Never disclose from it. Specifically:
        - Don't volunteer project, repo, client or company names, what was built or \
        committed, meeting topics, or who else they met, called or messaged.
        - Don't mention these notes exist, and don't say you have access to a log.
        - If asked what they're working on, stay general ("heads-down on work stuff") \
        unless this contact clearly already knows the specifics from the conversation.
        - If a question needs a detail that's only in here, say they'll follow up \
        themselves rather than answering from it.
        - Whether they are in a meeting or free right now IS fine to share -- that \
        is the one thing a person waiting on a reply actually needs to know.


        """
        if !live.isEmpty {
            block += "RIGHT NOW:\n\(live)\n\n"
        }
        for (day, text) in summaries {
            block += "--- \(day) ---\n\(text)\n\n"
        }
        block += "END OF BACKGROUND.\n\n"
        return block
    }

    private func cleanReply(_ raw: String) -> String? {
        var s = raw
            .replacingOccurrences(of: #"\*{1,3}([^*]+)\*{1,3}"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #"`{1,3}[^`]*`{1,3}"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        s = s.components(separatedBy: "\n")
            .filter { !$0.hasPrefix("#") }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        let sentences = s.components(separatedBy: ". ").filter { !$0.isEmpty }.prefix(3)
        let short = sentences.joined(separator: ". ")
        return short.hasSuffix(".") ? short : short + "."
    }
}
