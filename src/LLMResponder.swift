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

    /// Generate a reply for a contact based on their message preview and
    /// previous conversation history in this meeting.
    func reply(for contact: String,
               messagePreview: String?,
               history: [(role: String, text: String)]) -> String? {
        let msgs = messagePreview != nil ? [messagePreview!] : []
        let prompt = buildPrompt(contact: contact, history: history, newMessages: msgs)
        do {
            let raw = try momGenerator.runPrompt(prompt)
            return cleanReply(raw)
        } catch {
            cblog("LLMResponder: failed — \(error)")
            return nil
        }
    }

    private func buildPrompt(contact: String,
                             history: [(role: String, text: String)],
                             newMessages: [String]) -> String {
        var p = personality + "\n\nContact: \(contact)\n"
        if !history.isEmpty {
            p += "\nConversation so far:\n"
            for (role, text) in history.suffix(6) {
                p += "- \(role): \(text)\n"
            }
        }
        p += "\nTheir latest message(s):\n"
        for msg in newMessages { p += "- \(msg)\n" }
        p += "\nRespond in character. Keep it under 3 sentences. No markdown. No code blocks.\n"
        p += NikxelSettings.languageInstruction
        if NikxelSettings.language.lowercased() == "auto" {
            p += " Match the contact's own language/tone — if they write in Hindi or Hinglish, reply the same way; if they write in English, reply in English."
        }
        return p
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
