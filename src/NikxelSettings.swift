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

/// When the WhatsApp bot is allowed to answer on the user's behalf.
///
/// `.meetings` is the original (and still default) behaviour: the user is
/// visibly busy, so a stand-in reply is clearly better than silence. The other
/// two run all day, which is a bigger promise -- hence `.unattended` as the
/// recommended always-on setting: it only speaks once a message has sat
/// genuinely unanswered, so the user still gets first refusal on everything.
enum WABotMode: String, CaseIterable {
    /// Only while MeetingDetector says a meeting is on. Replies immediately.
    case meetings
    /// Any time, but only after the message has gone unanswered for
    /// `waUnattendedMinutes`. During a meeting, replies immediately -- waiting
    /// five minutes to tell someone "he's in a meeting" defeats the point.
    case unattended
    /// Any time, immediately. The bot will often beat the user to the reply.
    case always

    var displayName: String {
        switch self {
        case .meetings: return "Only during meetings"
        case .unattended: return "Any time, if unanswered for a while"
        case .always: return "Any time, immediately"
        }
    }

    /// Whether this mode wants the poller running outside a meeting.
    var runsOutsideMeetings: Bool { self != .meetings }
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
        var noteFormat: String?
        var connectedAgent: String?
        var whatsappConnected: Bool?
        var onboardingCompleted: Bool?
        var botMemoryDays: Int?
        var googleSyncEnabled: Bool?
        var summaryTemplate: String?
        var waBotMode: String?
        var waGroupReplies: Bool?
        var waUnattendedMinutes: Int?
        var waWorkContext: Bool?
        var waDraftOnly: Bool?
        var waQuietHours: Bool?
        var waQuietFrom: Int?
        var waQuietTo: Int?
        var waChatTasks: Bool?
        var projectsRoot: String?
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
    ///
    /// Unset falls back to the macOS account's first name, then to "Me". It
    /// used to fall back to the author's own name, which meant every other
    /// person who installed Nikxel got summaries calling them Nikhil.
    static var userName: String {
        get {
            let raw = load().userName?.trimmingCharacters(in: .whitespaces) ?? ""
            if !raw.isEmpty { return raw }
            return accountFirstName ?? "Me"
        }
        set { save { $0.userName = newValue } }
    }

    /// True once the user has actually told us their name -- the prompt uses
    /// this to decide between naming them and referring to them neutrally,
    /// rather than asserting a guessed name as fact.
    static var hasUserName: Bool {
        !(load().userName?.trimmingCharacters(in: .whitespaces) ?? "").isEmpty
    }

    /// First word of the macOS account's full name ("Prince Choudhary" ->
    /// "Prince"). nil when the account name is a bare username like "admin"
    /// or an email, which would read worse than no name at all.
    static var accountFirstName: String? {
        firstName(fullName: NSFullUserName(), account: NSUserName())
    }

    /// Split out from `accountFirstName` so it can be checked without a real
    /// macOS account -- see check_user_name.swift.
    static func firstName(fullName: String, account: String) -> String? {
        let full = fullName.trimmingCharacters(in: .whitespaces)
        guard let first = full.split(separator: " ").first.map(String.init),
              first.count > 1,
              // Letters only: rules out "admin2", emails, and "MacBook-Air".
              first.rangeOfCharacter(from: CharacterSet.letters.inverted) == nil,
              // A single word identical to the short username is a login, not
              // a name ("princechoudhary"). With a surname attached it's real.
              full.contains(" ") || first.lowercased() != account.lowercased()
        else { return nil }
        return first.prefix(1).uppercased() + first.dropFirst()
    }

    /// The user's own display name as it appears in THEIR WhatsApp account
    /// (often the full name, e.g. "Priya Sharma") — used to filter the
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

    /// How many days of end-of-day summaries the WhatsApp bot gets as context
    /// before writing a reply. 0 turns it off entirely.
    ///
    /// Kept small on purpose: the context is prepended to every reply prompt,
    /// so each extra day costs latency on every message, and older days are
    /// rarely what a contact is asking about.
    static var botMemoryDays: Int {
        get { max(0, min(14, load().botMemoryDays ?? 3)) }
        set { save { $0.botMemoryDays = max(0, min(14, newValue)) } }
    }

    /// Whether a finished meeting summary offers to push its Action Items to
    /// Google Tasks and its follow-ups to Google Calendar.
    ///
    /// On by default, because it still does nothing until the user has
    /// explicitly connected a Google account and granted write scopes --
    /// connecting IS the opt-in, and every push is confirmed in a dialog that
    /// lists each item first.
    static var googleSyncEnabled: Bool {
        get { load().googleSyncEnabled ?? true }
        set { save { $0.googleSyncEnabled = newValue } }
    }

    /// When the WhatsApp bot may reply. See `WABotMode`.
    static var waBotMode: WABotMode {
        get { WABotMode(rawValue: load().waBotMode ?? "") ?? .meetings }
        set { save { $0.waBotMode = newValue.rawValue } }
    }

    /// Whether group chats are eligible for auto-replies at all.
    ///
    /// Off by default, and deliberately not a plain on/off: when enabled, only
    /// messages that @-mention the user are answered. A bot that replies to
    /// every message in every group is the fastest way to get the user muted by
    /// everyone they know, and most group traffic isn't addressed to them.
    static var waGroupReplies: Bool {
        get { load().waGroupReplies ?? false }
        set { save { $0.waGroupReplies = newValue } }
    }

    /// How long a message must sit unanswered before `.unattended` mode replies.
    /// Clamped to 1...120 minutes.
    static var waUnattendedMinutes: Int {
        get { max(1, min(120, load().waUnattendedMinutes ?? 5)) }
        set { save { $0.waUnattendedMinutes = max(1, min(120, newValue)) } }
    }

    /// Whether the bot is told what the user is doing right now and today so
    /// far (foreground app, meeting state, today's totals) on top of the
    /// `botMemoryDays` of finished day summaries.
    ///
    /// On by default: without it the bot answers "any update on X?" with
    /// nothing useful until the 10pm summary exists, so the whole current day
    /// is a blind spot. Everything it adds is covered by the same
    /// non-disclosure rules as the day summaries.
    static var waWorkContext: Bool {
        get { load().waWorkContext ?? true }
        set { save { $0.waWorkContext = newValue } }
    }

    /// Type the reply into WhatsApp's message box and stop there, instead of
    /// pressing Enter.
    ///
    /// The honest way to start: you see exactly what the bot would have said,
    /// in the real chat, and send it with one keystroke or delete it. Off by
    /// default because the feature's whole point is answering while you can't.
    static var waDraftOnly: Bool {
        get { load().waDraftOnly ?? false }
        set { save { $0.waDraftOnly = newValue } }
    }

    /// Don't answer between `waQuietFrom` and `waQuietTo`. On by default --
    /// nothing good comes of a bot that is awake when you aren't, and the
    /// setting does nothing at all in meetings-only mode, where a meeting is
    /// already the trigger.
    static var waQuietHours: Bool {
        get { load().waQuietHours ?? true }
        set { save { $0.waQuietHours = newValue } }
    }

    /// Hour (0-23) quiet hours begin. Default 22.
    static var waQuietFrom: Int {
        get { max(0, min(23, load().waQuietFrom ?? 22)) }
        set { save { $0.waQuietFrom = max(0, min(23, newValue)) } }
    }

    /// Hour (0-23) quiet hours end. Default 8. Wraps past midnight when it is
    /// less than `waQuietFrom`, which is the normal case.
    static var waQuietTo: Int {
        get { max(0, min(23, load().waQuietTo ?? 8)) }
        set { save { $0.waQuietTo = max(0, min(23, newValue)) } }
    }

    /// Whether a chat message that is plainly an ask ("send the deck by Friday")
    /// becomes a Google Task.
    ///
    /// On by default and still free: it rides the reply the agent is already
    /// writing rather than making a second call, and does nothing until a
    /// Google account with Tasks access is connected.
    static var waChatTasks: Bool {
        get { load().waChatTasks ?? true }
        set { save { $0.waChatTasks = newValue } }
    }

    /// Folder scanned for git repos when building the day report and the
    /// WhatsApp bot's "what are you working on" context.
    ///
    /// Defaults to ~/Desktop, which is where this started, but pointing it at
    /// the actual projects folder is both faster and more accurate: the scan
    /// walks every subdirectory looking for `.git`, and most of a Desktop is
    /// not projects.
    static var projectsRoot: String {
        get {
            let raw = load().projectsRoot?.trimmingCharacters(in: .whitespaces) ?? ""
            guard !raw.isEmpty else {
                return FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent("Desktop", isDirectory: true).path
            }
            return (raw as NSString).expandingTildeInPath
        }
        set { save { $0.projectsRoot = newValue } }
    }

    /// Which summary template is active -- the slug of a file in
    /// `~/.nikxel/templates/`. See SummaryTemplates, which owns the files.
    ///
    /// "default" is a template whose every line is a comment, so the shipped
    /// prompt is used unchanged unless somebody picks a role or writes their own.
    static var summaryTemplate: String {
        get {
            let raw = load().summaryTemplate?.trimmingCharacters(in: .whitespaces) ?? ""
            return raw.isEmpty ? "default" : raw
        }
        set { save { $0.summaryTemplate = newValue } }
    }

    /// The active template's instructions, comments stripped.
    static var summaryStyle: String { SummaryTemplates.activeInstructions }

    /// Ready-to-drop-into-a-prompt form of `summaryStyle`. Empty when the
    /// active template adds nothing, so the default prompt is unchanged.
    static var summaryStyleInstruction: String {
        let style = summaryStyle
        guard !style.isEmpty else { return "" }
        return """
        HOUSE STYLE -- the person this summary is for has asked for the following. \
        These override the section-by-section instructions below wherever the two \
        disagree, including dropping a section entirely, renaming one, reordering \
        them, or adding one that isn't listed.

        Three limits on that, which the house style cannot override:
        - Never invent content to satisfy a style instruction. Attendees, \
        decisions, owners, dates, numbers, file paths and identifiers still come \
        only from the transcript. If a requested section has nothing in the \
        transcript to fill it, write "- None." rather than producing something.
        - If you keep an action-items or follow-up-meetings section, keep its \
        heading spelled exactly "## Action Items" and "## Follow-Up Meetings". \
        Those two are read back by name when sending tasks to Google Tasks and \
        Calendar, and a renamed heading silently stops that working.
        - These instructions were written with meetings in mind. If one of them \
        makes no sense for the content you were actually given, ignore that one.

        \(style)

        END OF HOUSE STYLE.
        """
    }

    /// File format for generated notes/MOMs. The Markdown the agent wrote is
    /// always saved; anything else is rendered alongside it.
    static var noteFormat: NoteExporter.Format {
        get { NoteExporter.Format(rawValue: load().noteFormat ?? "") ?? .markdown }
        set { save { $0.noteFormat = newValue.rawValue } }
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
