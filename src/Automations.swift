import AppKit

/// Runs the user's automations (Automation.swift): the scheduled ones from a
/// timer, the rest when MeetingCoordinator or DayLogger finish a summary, and
/// any from the Nikxel window's Run now. One at a time, each through a fresh
/// ChatSession, so an automation can do what the chat can (answer, draft an
/// email, make an ERP task) and nothing more. Results go on a card and into
/// the window's Recent runs (~/.nikxel/automation-runs.json).
final class Automations {
    static let shared = Automations()

    /// The window redraws when a run finishes.
    var onChange: (() -> Void)?
    private(set) var runs: [[String: Any]] = []
    private(set) var running: String?
    private var agent: MOMGenerator?
    private var timer: Timer?
    private var queue: [(Automation, URL?)] = []
    private let runsFile = URL(fileURLWithPath: NSHomeDirectory() + "/.nikxel/automation-runs.json")

    func start(agent: MOMGenerator) {
        self.agent = agent
        runs = (try? Data(contentsOf: runsFile)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [[String: Any]] } ?? []
        timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in self?.tick() }
    }

    private func tick() {
        var list = Automation.load(), changed = false
        let now = Date()
        for i in list.indices where list[i].due(at: now) {
            list[i].lastRun = Automation.minuteKey(now)
            changed = true
            enqueue(list[i], file: nil)
        }
        if changed { Automation.save(list) }
    }

    /// A summary was just written: "meeting", "day" or "week", with its .md.
    func fire(_ trigger: String, file: URL?) {
        for a in Automation.load() where a.enabled && a.trigger == trigger { enqueue(a, file: file) }
    }

    /// Run now, from the window: an event automation gets the latest summary of its kind.
    func runNow(_ a: Automation) {
        let kind = ["meeting": "meetings", "day": "daily", "week": "weekly"][a.trigger]
        let latest = kind.flatMap { k in SummaryLibrary.scan().first { $0.kind == k } }
        enqueue(a, file: latest.map { $0.file.deletingPathExtension().appendingPathExtension("md") })
    }

    private func enqueue(_ a: Automation, file: URL?) {
        queue.append((a, file))
        if running == nil { next() }
    }

    private func next() {
        guard !queue.isEmpty, let agent else { running = nil; onChange?(); return }
        let (a, file) = queue.removeFirst()
        running = a.id
        onChange?()
        var attach = ""
        if let file, let md = try? String(contentsOf: file, encoding: .utf8) {
            let what = ["meeting": "the meeting summary that was just written", "day": "today's day summary", "week": "this week's summary"][a.trigger] ?? "the summary"
            attach = "### this automation's input: \(what)\n\(md.prefix(15_000))"
        }
        let text = "Automation “\(a.name)” (\(a.when.lowercased())): \(a.instruction)\n\nIf there's nothing to do, reply only SKIP."
        ChatSession(agent: agent).send(text, attach: attach) { [weak self] r in
            self?.finished(a, file: file, reply: r["text"] as? String ?? "", error: r["error"] as? Bool ?? false)
            self?.next()
        }
    }

    private func finished(_ a: Automation, file: URL?, reply: String, error: Bool) {
        let text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        let skipped = text.uppercased().hasPrefix("SKIP")
        let page = file.map { $0.deletingPathExtension().appendingPathExtension("html") }.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
        runs.insert(["id": a.id, "name": a.name, "t": Date().timeIntervalSince1970, "text": skipped ? "" : text,
                     "skipped": skipped, "error": error, "file": page?.path ?? ""], at: 0)
        runs = Array(runs.prefix(60))
        if let data = try? JSONSerialization.data(withJSONObject: runs) { try? data.write(to: runsFile, options: .atomic) }
        cblog("Automations: ran “\(a.name)” → \(skipped ? "skip" : error ? "error" : "\(text.count) chars")")
        // A card only when there's something to say and the avatar is up; the
        // window's Recent runs has every result either way.
        guard !skipped, NikxelView.main?.window?.isVisible == true else { return }
        let lines = text.split(separator: "\n").map { $0.replacingOccurrences(of: "**", with: "").trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        NikxelView.tell(icon: "⚡️", title: a.name, lines: Array(lines.prefix(3)) + (lines.count > 3 ? ["…"] : []),
                        kind: error ? .warning : .info, lifetime: 40,
                        action: { DashboardWindowController.show(section: "automations") })
    }

    // MARK: - Making them

    /// The user's request as an automation to review, or nil.
    func make(_ request: String, done: @escaping (Automation?) -> Void) {
        guard let agent else { return done(nil) }
        DispatchQueue.global(qos: .userInitiated).async {
            let reply = try? agent.runPrompt(Automation.makePrompt(request: request), kind: "automation", claudeModel: "haiku", timeout: 60)
            let made = reply.flatMap { Automation.parse($0).first?.0 }
            DispatchQueue.main.async { done(made) }
        }
    }

    /// Automations suggested from the last two weeks of the user's work.
    func suggest(done: @escaping ([(Automation, why: String)]) -> Void) {
        guard let agent else { return done([]) }
        let existing = Automation.load()
        DispatchQueue.global(qos: .userInitiated).async {
            let root = URL(fileURLWithPath: NSHomeDirectory() + "/Documents/nikxel")
            let context = [NikxelSettings.userContextBlock,
                           ChatContext.build(ChatContext.localBlocks(root: root, today: Date()), cap: 40_000)].joined(separator: "\n\n")
            let reply = try? agent.runPrompt(Automation.suggestPrompt(context: context, existing: existing),
                                             kind: "automation-suggest", claudeModel: "sonnet", timeout: 150)
            let list = reply.map(Automation.parse) ?? []
            DispatchQueue.main.async { done(list) }
        }
    }
}
