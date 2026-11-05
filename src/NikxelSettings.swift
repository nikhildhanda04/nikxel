import Foundation

/// User-editable preferences shared across the meeting/notes/chat/daily-summary
/// LLM pipelines. Backed by a small JSON file (not UserDefaults) so it's easy
/// for the user to open and edit directly, same as `bot_personality.txt`.
enum NikxelSettings {
    private struct Stored: Codable {
        var userName: String?
        var language: String?
        var waOwnName: String?
    }

    private static let fileURL: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".nikxel", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("settings.json")
    }()

    private static func load() -> Stored {
        guard let data = try? Data(contentsOf: fileURL),
              let s = try? JSONDecoder().decode(Stored.self, from: data) else { return Stored() }
        return s
    }

    private static func save(_ mutate: (inout Stored) -> Void) {
        var s = load()
        mutate(&s)
        guard let data = try? JSONEncoder().encode(s) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    /// The user's real first name. Fed into the meeting prompt so the LLM
    /// knows exactly who "Me" (the mic-channel speaker) actually is instead
    /// of guessing from context and occasionally attributing "Me"'s words to
    /// someone else mentioned in the conversation, or vice versa.
    static var userName: String {
        get {
            let raw = load().userName?.trimmingCharacters(in: .whitespaces) ?? ""
            return raw.isEmpty ? "Nikhil" : raw
        }
        set { save { $0.userName = newValue } }
    }

    /// The user's own display name as it appears in THEIR WhatsApp account
    /// (often the full name, e.g. "Nikhil Dhanda") — used to filter the
    /// user's own messages/rows out of chat scraping. Falls back to
    /// `userName` if not set separately.
    static var waOwnName: String {
        get {
            let raw = load().waOwnName?.trimmingCharacters(in: .whitespaces) ?? ""
            return raw.isEmpty ? userName : raw
        }
        set { save { $0.waOwnName = newValue } }
    }

    /// Output language preference.
    /// - "auto" (default): match whatever language the source content is in
    ///   — English, Hindi, Hinglish, or anything else.
    /// - any other value (e.g. "English", "Hindi"): always force that language.
    static var language: String {
        get {
            let raw = load().language?.trimmingCharacters(in: .whitespaces) ?? ""
            return raw.isEmpty ? "auto" : raw
        }
        set { save { $0.language = newValue } }
    }

    /// Ready-to-drop-into-a-prompt instruction honoring `language`.
    static var languageInstruction: String {
        if language.lowercased() == "auto" {
            return "The source content may be in English, Hindi, Hinglish (mixed), or any other language. Write your output in that SAME language — don't translate to English unless the source itself is already in English."
        }
        return "Always write your output in \(language), regardless of what language the source content is in. Translate as needed."
    }
}
