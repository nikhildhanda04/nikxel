import Foundation

/// The CLI-based coding agent Nikxel shells out to for MOM/notes generation
/// and chat replies (see MOMGenerator's per-agent `AgentBackend`).
enum CodingAgent: String, Codable, CaseIterable, Hashable {
    case claude
    case opencode
    case codex

    var displayName: String {
        switch self {
        case .claude: return "Claude Code"
        case .opencode: return "OpenCode"
        case .codex: return "Codex"
        }
    }

    /// Shell command that installs this agent, shown (and copyable) in the
    /// setup wizard when it isn't found.
    var installCommand: String {
        switch self {
        case .claude: return "npm install -g @anthropic-ai/claude-code"
        case .opencode: return "curl -fsSL https://opencode.ai/install | bash"
        case .codex: return "npm install -g @openai/codex"
        }
    }

    /// Process names to look for when checking "is this agent running" —
    /// mirrors AgentMonitor.swift's cosmetic `ps aux` detection list.
    var processNames: [String] {
        switch self {
        case .claude: return ["claude", "claude-code"]
        case .opencode: return ["opencode"]
        case .codex: return ["codex"]
        }
    }
}

/// User-editable preferences shared across the meeting/notes/chat/daily-summary
/// LLM pipelines. Backed by a small JSON file (not UserDefaults) so it's easy
/// for the user to open and edit directly, same as `bot_personality.txt`.
enum NikxelSettings {
    private struct Stored: Codable {
        var userName: String?
        var language: String?
        var waOwnName: String?
        var transcriptionLanguage: String?
        var connectedAgent: String?
        var whatsappConnected: Bool?
        var onboardingCompleted: Bool?
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
            return "The source content may be in English, Hindi, Hinglish (mixed), or any other language. Write your output in that SAME language — don't translate to English unless the source itself is already in English. For Hindi, always write it in Latin letters as Hinglish (e.g. \"kal meeting mein discuss karenge\") — never in Devanagari script. The transcript romanizes Hindi phonetically, so English and technical words may arrive misspelled (\"pheetchhar\", \"diployo\", \"shedyol\"); restore their normal English spelling (feature, deploy, schedule)."
        }
        return "Always write your output in \(language), regardless of what language the source content is in. Translate as needed. If that language is Hindi, write it in Latin letters as Hinglish — never in Devanagari script."
    }

    /// Spoken language passed to whisper: "en", "hi", or "auto".
    ///
    /// Deliberately NOT "auto" by default. Measured on the base and small
    /// models: auto-detect put Hindi speech into Urdu script, and on the small
    /// model it mangled plain English into Devanagari. Naming the language
    /// explicitly was correct in every case tested. Hinglish works under "en"
    /// (English words stay English, Hindi gets rendered in English) or "hi"
    /// (everything transliterated into Devanagari) -- "en" reads better in a
    /// meeting summary, so it is the default.
    static var transcriptionLanguage: String {
        get {
            let raw = load().transcriptionLanguage?.trimmingCharacters(in: .whitespaces) ?? ""
            return raw.isEmpty ? "en" : raw
        }
        set { save { $0.transcriptionLanguage = newValue } }
    }

    /// Which CLI agent MOMGenerator shells out to. Defaults to Claude Code —
    /// the only backend that worked before the onboarding agent picker existed.
    static var connectedAgent: CodingAgent {
        get { CodingAgent(rawValue: load().connectedAgent ?? "") ?? .claude }
        set { save { $0.connectedAgent = newValue.rawValue } }
    }

    /// Whether the onboarding wizard has confirmed a WhatsApp Web login in
    /// the bot's isolated Chrome profile. Purely informational — the actual
    /// connection lives in the Chrome profile dir; this just drives UI state.
    static var whatsappConnected: Bool {
        get { load().whatsappConnected ?? false }
        set { save { $0.whatsappConnected = newValue } }
    }

    /// Gates auto-showing the onboarding wizard on launch.
    static var onboardingCompleted: Bool {
        get { load().onboardingCompleted ?? false }
        set { save { $0.onboardingCompleted = newValue } }
    }
}

/// Where the running avatar's sprite sheet comes from. The bundled sheet is the
/// default; dropping one at ~/.nikxel/sprites.png overrides it, which is what
/// the onboarding "use your own avatar" step writes.
enum NikxelSprites {
    /// Sheets are a 4-column x 10-row grid of 64x64 frames (one row per state,
    /// see NikxelView.stateRow) -- i.e. 256x640.
    static let frameSize = 64
    static let cols = 4
    static let rows = 10

    static let customURL: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".nikxel/sprites.png")

    static var hasCustom: Bool { FileManager.default.isReadableFile(atPath: customURL.path) }

    static var activePath: String? {
        if hasCustom { return customURL.path }
        return Bundle.main.path(forResource: "sprites", ofType: "png")
    }

    /// Posted after the custom sheet is installed or removed so the live avatar
    /// picks it up without an app restart.
    static let changedNotification = Notification.Name("NikxelSpritesChanged")
}
