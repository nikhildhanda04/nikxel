import Foundation

/// The two per-contact lists the WhatsApp bot consults: who it must never
/// answer, and who it may speak freely in front of.
///
/// Plain text files in `~/.nikxel/`, one name per line, `#` for comments —
/// same shape as `bot_personality.txt` and the summary templates, so they can
/// be edited in any editor without Nikxel running. Re-read on every check
/// rather than cached: editing the file should take effect on the next
/// message, not the next launch.
enum WAContactLists {

    enum Kind: String {
        case neverReply = "never_reply"
        case trusted = "trusted_contacts"

        var fileName: String { rawValue + ".txt" }

        var seedContents: String {
            switch self {
            case .neverReply:
                return """
                # Contacts Nikxel must never auto-reply to, one name per line.
                #
                # Write the name exactly as it appears in your WhatsApp chat list.
                # A first name on its own is enough as long as it's 3+ letters --
                # "Asha" matches the chat "Asha Verma".
                #
                # Entries here beat every other setting: not during meetings, not
                # when tagged in a group, not ever.
                #
                # Lines starting with # are ignored. Examples:
                # Mum
                # Priya Sharma
                """
            case .trusted:
                return """
                # Contacts the bot may speak freely in front of, one name per line.
                #
                # By default the bot is told never to disclose what you are
                # working on -- project names, repos, clients, meeting topics, who
                # else you spoke to -- because it answers whoever happens to write
                # to you. Names listed here are exempt: it will answer them with
                # the specifics instead of "heads-down on work stuff".
                #
                # Only list people who would already be told. A co-founder,
                # your own team. Not a client, not a group.
                #
                # Write the name exactly as it appears in your WhatsApp chat list.
                # A first name on its own is enough as long as it's 3+ letters.
                #
                # Lines starting with # are ignored. Examples:
                # Anjali
                # Rahul Mehta
                """
            }
        }
    }

    static func fileURL(_ kind: Kind) -> URL {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".nikxel", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(kind.fileName)
    }

    /// Writes the commented template if the file doesn't exist yet. Never
    /// overwrites — an empty-but-present file is a user who deleted the
    /// comments, not a user who needs them back.
    @discardableResult
    static func seedIfMissing(_ kind: Kind) -> URL {
        let url = fileURL(kind)
        if !FileManager.default.fileExists(atPath: url.path) {
            try? kind.seedContents.write(to: url, atomically: true, encoding: .utf8)
        }
        return url
    }

    /// The names on a list, comments and blanks stripped.
    static func names(_ kind: Kind) -> [String] {
        guard let text = try? String(contentsOf: fileURL(kind), encoding: .utf8) else { return [] }
        return parse(text)
    }

    /// Split out from `names` so the matching rules can be checked without
    /// writing to the user's home directory — see check_wa_bot.swift.
    static func parse(_ text: String) -> [String] {
        text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    static func contains(_ kind: Kind, contact: String) -> Bool {
        matches(names(kind), contact: contact)
    }

    /// Whether `contact` is on `list`.
    ///
    /// Tolerant in the same way the conversation-header verification is: a chat
    /// called "Asha Verma" is matched by an entry of "Asha", because that is how
    /// people actually write these lists. Prefix matching is restricted to
    /// entries of 3+ characters, so a stray "Al" can't silence Alice, Alex and
    /// Ali at once.
    static func matches(_ list: [String], contact: String) -> Bool {
        let c = normalize(contact)
        guard !c.isEmpty else { return false }
        for raw in list {
            let n = normalize(raw)
            if n.isEmpty { continue }
            if n == c { return true }
            if n.count >= 3 && (c.hasPrefix(n) || n.hasPrefix(c)) { return true }
        }
        return false
    }

    private static func normalize(_ s: String) -> String {
        s.lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
