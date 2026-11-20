import Foundation
import AppKit
import ApplicationServices

class DayLogger {
    /// The one instance, so LLMResponder can ask what today looks like without
    /// NikxelApp threading a reference through MOMGenerator into the chatbot.
    private(set) static weak var current: DayLogger?

    private let momGenerator: MOMGenerator
    private let logDir: URL
    private let summaryDir: URL
    private let meetingsDir: URL
    private let scanRoot: URL
    private var sampleTimer: Timer?
    /// Bumped to cancel a scheduled summary.
    private var summaryGeneration = 0
    private var lastSample: (app: String, title: String)?
    private let sampleInterval: TimeInterval = 15
    // Cap each sample's attributed duration so a sleep-through-the-night gap
    // doesn't get charged to whatever app was foreground when the lid closed.
    private let durationCap: TimeInterval = 5 * 60
    // Fire EOD summary at this hour (24h). 22 = 10pm.
    private let summaryHour: Int = 22

    init(momGenerator: MOMGenerator) {
        self.momGenerator = momGenerator
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.logDir = home.appendingPathComponent("Library/Application Support/Nikxel/days", isDirectory: true)
        self.summaryDir = Self.summaryDirectory
        self.meetingsDir = home.appendingPathComponent("Documents/nikxel/meetings", isDirectory: true)
        self.scanRoot = URL(fileURLWithPath: NikxelSettings.projectsRoot, isDirectory: true)
        try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: summaryDir, withIntermediateDirectories: true)
        DayLogger.current = self
    }

    func start() {
        sample()
        sampleTimer = Timer.scheduledTimer(withTimeInterval: sampleInterval, repeats: true) { [weak self] _ in
            self?.sample()
        }
        scheduleSummary()
        scheduleWeek()
        scheduleMorning()
        backfillIfMissed()
        upgradeDailyPages()
    }

    /// Re-renders the last week's daily pages that predate the Send bar, so
    /// they can be crossed out and sent too. Their .md is untouched.
    func upgradeDailyPages() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            for back in 0..<7 {
                guard let date = Calendar.current.date(byAdding: .day, value: -back, to: Date()) else { continue }
                let md = self.summaryFileURL(for: date), page = md.deletingPathExtension().appendingPathExtension("html")
                guard let text = try? String(contentsOf: md, encoding: .utf8),
                      let html = try? String(contentsOf: page, encoding: .utf8), !html.contains("nx-pv") else { continue }
                try? DayPage.html(from: text, stats: self.dayStats(for: date), daily: true).write(to: page, atomically: true, encoding: .utf8)
            }
        }
    }

    func stop() {
        sampleTimer?.invalidate(); sampleTimer = nil
        summaryGeneration += 1
    }

    func generateSummaryNow() {
        generateSummary(for: Date())
    }

    /// Fired on the main thread right after an end-of-day summary is written,
    /// with the one-line digest for the avatar bubble and the file it came from.
    var onSummaryReady: ((String, URL) -> Void)?
    /// The same for the Sunday-morning week in review.
    var onWeekReady: ((String, URL) -> Void)?
    /// Each morning: the tasks the latest summary still has open, and its page.
    var onMorningTasks: (([String], URL) -> Void)?

    // MARK: - Digest

    /// The handful of numbers worth putting in a bubble. Separate from the
    /// narrative summary, which is prose and takes an agent run to produce.
    struct DayStats: Equatable {
        var codingSeconds: TimeInterval = 0
        /// All sampled foreground time, coding or not.
        var activeSeconds: TimeInterval = 0
        var meetings: Int = 0
        var messages: Int = 0
    }

    /// Frontmost-app names that count as coding. Matched as lowercase
    /// substrings, so "Visual Studio Code", "Code - Insiders" and "VSCodium"
    /// all land on "code".
    static let codingAppHints = [
        "code", "xcode", "vscodium", "cursor", "zed", "windsurf", "fleet",
        "terminal", "iterm", "ghostty", "warp", "alacritty", "kitty", "hyper", "wezterm",
        "sublime", "nova", "textmate", "neovim", "emacs",
        "android studio", "intellij", "pycharm", "webstorm", "goland", "phpstorm",
        "rubymine", "clion", "rider", "datagrip",
        "antigravity", "kiro",
    ]

    static func isCodingApp(_ name: String) -> Bool {
        let n = name.lowercased()
        return codingAppHints.contains { n.contains($0) }
    }

    /// Formats stats into the bubble's single line. nil when the day is empty
    /// enough that a bubble would say nothing -- better no bubble than
    /// "0 meetings".
    ///
    /// Pure, so it can be checked without a day of logs -- see
    /// check_day_digest.swift.
    static func digestLine(_ s: DayStats) -> String? {
        var parts: [String] = []
        let codingMins = Int((s.codingSeconds / 60).rounded())
        if codingMins >= 1 { parts.append("\(humanDuration(minutes: codingMins)) coding") }
        if s.meetings > 0 { parts.append("\(s.meetings) meeting\(s.meetings == 1 ? "" : "s")") }
        if s.messages > 0 { parts.append("\(s.messages) message\(s.messages == 1 ? "" : "s")") }
        if !parts.isEmpty { return parts.joined(separator: " · ") }

        // Nothing headline-worthy, but the Mac was clearly in use -- say that
        // rather than showing an empty bubble. Under half an hour, say nothing.
        let activeMins = Int(s.activeSeconds / 60)
        if activeMins >= 30 { return "\(humanDuration(minutes: activeMins)) at the Mac" }
        return nil
    }

    /// 200 -> "3h 20m", 45 -> "45m", 120 -> "2h".
    /// New messages seen in the chat log. It holds a preview snapshot of every
    /// chat on each poll, so counting lines counted snapshots (thousands a day).
    /// A chat's first sighting is what was already there; after that each
    /// preview it hadn't shown before is one new message. Seen-before, not just
    /// changed: previews flip between "typing…" and back all day.
    static func countMessages(_ entries: [[String: Any]]) -> Int {
        var seen: [String: Set<String>] = [:], n = 0
        for e in entries {
            guard let name = e["name"] as? String else { continue }
            let preview = e["preview"] as? String ?? ""
            guard seen[name] != nil else { seen[name] = [preview]; continue }
            if seen[name]!.insert(preview).inserted { n += 1 }
        }
        return n
    }

    static func humanDuration(minutes: Int) -> String {
        let h = minutes / 60, m = minutes % 60
        if h == 0 { return "\(m)m" }
        if m == 0 { return "\(h)h" }
        return "\(h)h \(m)m"
    }

    /// Counts today's coding time, meetings and WhatsApp messages off the same
    /// logs the narrative summary is built from.
    /// The seven days before `end` (a Sunday), added up for the week page.
    func weekStats(end: Date) -> DayStats {
        var stats = DayStats()
        for offset in 1...7 {
            guard let d = Calendar.current.date(byAdding: .day, value: -offset, to: end) else { continue }
            let s = dayStats(for: d)
            stats.codingSeconds += s.codingSeconds; stats.activeSeconds += s.activeSeconds
            stats.meetings += s.meetings; stats.messages += s.messages
        }
        return stats
    }

    func dayStats(for date: Date) -> DayStats {
        var stats = DayStats()

        // Foreground time, attributed the same way aggregateAppUsage does it:
        // each sample owns the gap until the next one, capped so a lid-closed
        // overnight gap isn't charged to whatever was open.
        if let content = try? String(contentsOf: logFileURL(for: date), encoding: .utf8) {
            var samples: [(t: TimeInterval, app: String)] = []
            for line in content.split(separator: "\n") {
                guard let data = line.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let t = obj["t"] as? TimeInterval,
                      let app = obj["app"] as? String else { continue }
                samples.append((t, app))
            }
            samples.sort { $0.t < $1.t }
            for i in samples.indices {
                let dur = i + 1 < samples.count
                    ? min(samples[i + 1].t - samples[i].t, durationCap)
                    : sampleInterval
                stats.activeSeconds += dur
                if Self.isCodingApp(samples[i].app) { stats.codingSeconds += dur }
            }
        }

        // Meetings: today's generated MOMs. ".transcript.txt" is excluded by
        // the .md check, so a meeting is never counted twice.
        if let files = try? FileManager.default.contentsOfDirectory(atPath: meetingsDir.path) {
            let prefix = Self.dayKey(date)
            stats.meetings = files.filter { $0.hasPrefix(prefix) && $0.hasSuffix(".md") }.count
        }

        stats.messages = Self.countMessages(WhatsAppActivityLogger.readLog(file: "chats", for: date))

        return stats
    }

    // MARK: - Live context

    private var liveCache: (text: String, at: Date, inMeeting: Bool)?
    /// `aggregateGit` shells out to git once per repo under ~/Desktop, and a
    /// busy chat can ask for this several times a minute. Ten minutes is
    /// still "what are you working on right now".
    private let liveCacheTTL: TimeInterval = 600

    /// What the user is doing right now and what today has looked like so far,
    /// as a few short lines. Fills the gap the end-of-day summaries leave: until
    /// 10pm, the whole current day is invisible to the WhatsApp bot, which is
    /// exactly the day someone is most likely to be asking about.
    func liveContext(inMeeting: Bool) -> String {
        // The meeting flag is part of the key, not just the payload: a meeting
        // can start or end inside the TTL, and "in a meeting right now" is the
        // one line in here the bot is allowed to repeat out loud.
        if let c = liveCache, c.inMeeting == inMeeting,
           Date().timeIntervalSince(c.at) < liveCacheTTL {
            return c.text
        }
        var lines: [String] = []
        lines.append(inMeeting ? "- In a meeting right now." : "- Not in a meeting right now.")

        if let last = lastSample {
            let title = last.title.trimmingCharacters(in: .whitespaces)
            lines.append(title.isEmpty
                ? "- Currently in: \(last.app)"
                : "- Currently in: \(last.app) — \"\(title.prefix(90))\"")
        }

        if let digest = Self.digestLine(dayStats(for: Date())) {
            lines.append("- Today so far: \(digest)")
        }

        let windows = recentWindows(limit: 8)
        if !windows.isEmpty {
            lines.append("- Recently open (newest first):\n" + windows.map { "  " + $0 }.joined(separator: "\n"))
        }

        let repos = findRepos()
        let edits = todaysEdits(repos: repos)
        if !edits.isEmpty {
            lines.append("- Code today, most recently touched project first:\n" + edits.split(separator: "\n")
                .prefix(50).map { "  " + $0 }.joined(separator: "\n"))
        }

        let week = recentWork(repos: repos, days: 7)
        if !week.isEmpty {
            lines.append("- Projects active this week (latest commits first):\n" + week.split(separator: "\n")
                .prefix(60).map { "  " + $0 }.joined(separator: "\n"))
        }

        // The literal asks made to coding agents today -- the clearest record
        // of which feature or bug is in hand, and the one thing git can't show
        // until it's committed.
        let asks = (aggregateClaudeSessions(for: Date()) + "\n" + aggregateOpencodeSessions(for: Date()))
            .split(separator: "\n").filter { !$0.isEmpty }.suffix(15)
            .map { "  " + Self.redactSecrets($0.count > 180 ? String($0.prefix(180)) + "…" : String($0)) }
        if !asks.isEmpty {
            lines.append("- Asked AI agents today (latest last):\n" + asks.joined(separator: "\n"))
        }

        let text = lines.joined(separator: "\n")
        liveCache = (text, Date(), inMeeting)
        return text
    }

    /// Prompts get pasted tokens and keys; none of that belongs in a prompt that
    /// writes messages to other people. Long unbroken alphanumeric runs (API
    /// tokens, keys, hashes) and the paste wrapper tag are dropped.
    static func redactSecrets(_ s: String) -> String {
        s.replacingOccurrences(of: #"<pasted_content[^>]*>"#, with: "", options: .regularExpression)
         .replacingOccurrences(of: #"[A-Za-z0-9_\-]{16,}"#, with: "[redacted]", options: .regularExpression)
    }

    /// The last few distinct windows from today's samples, newest first --
    /// documents, PRs, tickets, whatever the titles name.
    private func recentWindows(limit: Int) -> [String] {
        guard let content = try? String(contentsOf: logFileURL(for: Date()), encoding: .utf8) else { return [] }
        var seen = Set<String>(), out: [String] = []
        for line in content.split(separator: "\n").reversed() {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let app = obj["app"] as? String else { continue }
            let title = (obj["title"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            let entry = title.isEmpty ? app : "\(app) — \(title.prefix(90))"
            if seen.insert(entry).inserted { out.append(entry) }
            if out.count == limit { break }
        }
        return out
    }

    // MARK: - Sampling

    private func sample() {
        guard let app = NSWorkspace.shared.frontmostApplication else { return }
        let appName = app.localizedName ?? app.bundleIdentifier ?? "Unknown"
        let title = frontmostWindowTitle(for: app.processIdentifier) ?? ""
        if let last = lastSample, last.app == appName && last.title == title { return }
        lastSample = (appName, title)
        let entry: [String: Any] = [
            "t": Date().timeIntervalSince1970,
            "app": appName,
            "title": title
        ]
        appendLog(entry)
    }

    private func frontmostWindowTitle(for pid: pid_t) -> String? {
        let axApp = AXUIElementCreateApplication(pid)
        var windowRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &windowRef) == .success,
              let raw = windowRef else { return nil }
        let window = raw as! AXUIElement
        var titleRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleRef) == .success,
              let title = titleRef as? String else { return nil }
        return title
    }

    private func appendLog(_ entry: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: entry, options: []) else { return }
        var line = data
        line.append(0x0A)
        let url = logFileURL(for: Date())
        if FileManager.default.fileExists(atPath: url.path) {
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(line)
                try? handle.close()
            }
        } else {
            try? line.write(to: url, options: .atomic)
        }
    }

    private func logFileURL(for date: Date) -> URL {
        return logDir.appendingPathComponent("\(Self.dayKey(date)).jsonl")
    }

    private func summaryFileURL(for date: Date) -> URL {
        return summaryDir.appendingPathComponent("\(Self.dayKey(date)).md")
    }

    /// Where the end-of-day summaries live. Static so the WhatsApp bot can
    /// read them back without owning a DayLogger.
    static var summaryDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/nikxel/daily", isDirectory: true)
    }

    /// The most recent `days` end-of-day summaries, newest first, skipping
    /// days with no summary (the app wasn't running, or it's before 10pm).
    ///
    /// Each is truncated: a full day's summary runs to a few KB, and this gets
    /// prepended to every WhatsApp reply prompt, where it would otherwise
    /// dominate the actual message and slow every response down.
    /// `directory` and `now` are injectable so this can be checked against a
    /// temp folder and a fixed date -- see check_bot_memory.swift.
    static func recentSummaries(days: Int,
                                maxCharsPerDay: Int = 1200,
                                in directory: URL? = nil,
                                now: Date = Date()) -> [(day: String, text: String)] {
        guard days > 0 else { return [] }
        let dir = directory ?? summaryDirectory
        let cal = Calendar.current
        var out: [(String, String)] = []
        // Start at yesterday: today's summary doesn't exist until 10pm, and
        // looking back `days` from today would silently give one day fewer.
        for offset in 1...days {
            guard let date = cal.date(byAdding: .day, value: -offset, to: now) else { continue }
            let url = dir.appendingPathComponent("\(dayKey(date)).md")
            guard let raw = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            out.append((dayKey(date), text.count > maxCharsPerDay
                        ? String(text.prefix(maxCharsPerDay)) + "…"
                        : text))
        }
        return out
    }

    private static let dayKeyFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        return fmt
    }()

    private static func dayKey(_ date: Date) -> String {
        dayKeyFormatter.string(from: date)
    }

    // MARK: - Scheduling

    private func nextSummaryFireDate(after reference: Date) -> Date {
        let cal = Calendar.current
        var comps = cal.dateComponents([.year, .month, .day], from: reference)
        comps.hour = summaryHour; comps.minute = 0; comps.second = 0
        let today = cal.date(from: comps) ?? reference
        if today > reference { return today }
        return cal.date(byAdding: .day, value: 1, to: today) ?? reference
    }

    /// On the wall clock, not a Timer: a Timer's countdown stops while the
    /// Mac sleeps, so every nap in the evening pushed 10pm later.
    private func scheduleSummary() {
        summaryGeneration += 1
        let generation = summaryGeneration
        let interval = max(1, nextSummaryFireDate(after: Date()).timeIntervalSinceNow)
        DispatchQueue.main.asyncAfter(wallDeadline: .now() + interval) { [weak self] in
            guard let self = self, generation == self.summaryGeneration else { return }
            self.generateSummary(for: Date())
            self.scheduleSummary()
        }
    }

    /// Idempotent: writes today's summary if past the summary hour and the
    /// file isn't there yet. Safe to call from app launch, wake-from-sleep,
    /// and external triggers (LaunchAgent).
    func backfillIfMissed() {
        weekBackfill()
        morningBackfill()
        let now = Date()
        let cal = Calendar.current
        var comps = cal.dateComponents([.year, .month, .day], from: now)
        comps.hour = summaryHour; comps.minute = 0; comps.second = 0
        guard let todayFire = cal.date(from: comps), now >= todayFire else { return }
        if FileManager.default.fileExists(atPath: summaryFileURL(for: now).path) { return }
        generateSummary(for: now)
    }

    // MARK: - Open tasks

    /// The bullets under "## Open tasks", without their "— open" tail. The
    /// summary prompt carries this list from day to day, dropping what a later
    /// day shows done, so the latest summary's list is the whole backlog.
    static func openTasks(in markdown: String) -> [String] {
        var out: [String] = [], inside = false
        for raw in markdown.components(separatedBy: .newlines) {
            if raw.hasPrefix("## ") { inside = raw.dropFirst(3).trimmingCharacters(in: .whitespaces).lowercased() == "open tasks"; continue }
            guard inside, raw.hasPrefix("- ") || raw.hasPrefix("* ") else { continue }
            var t = raw.dropFirst(2).trimmingCharacters(in: .whitespaces)
            if NoteExporter.isNone(t) || t.lowercased().hasPrefix("nothing") { continue }
            // Ticked on the day page.
            if t.range(of: #"\s+[—–-]\s*\**done\**\.?\s*$"#, options: [.regularExpression, .caseInsensitive]) != nil { continue }
            if let r = t.range(of: #"\s+[—–-]\s*\**(open|unclear)\**\.?\s*$"#, options: [.regularExpression, .caseInsensitive]) {
                t = String(t[..<r.lowerBound])
            }
            out.append(t)
        }
        return out
    }

    /// The open tasks, once a day: the first launch, wake or unlock from 5am
    /// on, whenever the day actually starts. 5, not midnight, so a late-night
    /// unlock doesn't use up the next day's reminder. A Mac that never sleeps
    /// gets it at 5 and finds it waiting.
    private static let morningHour = 5
    private var morningGeneration = 0
    private static let morningShownKey = "nikxel.openTasksShownDay"

    private func scheduleMorning() {
        morningGeneration += 1
        let generation = morningGeneration
        guard let fire = Calendar.current.nextDate(after: Date(), matching: DateComponents(hour: Self.morningHour, minute: 0, second: 0),
                                                   matchingPolicy: .nextTime) else { return }
        DispatchQueue.main.asyncAfter(wallDeadline: .now() + max(1, fire.timeIntervalSinceNow)) { [weak self] in
            guard let self = self, generation == self.morningGeneration else { return }
            self.morningBackfill()
            self.scheduleMorning()
        }
    }

    func morningBackfill() {
        let now = Date(), today = Self.dayKey(now)
        guard Calendar.current.component(.hour, from: now) >= Self.morningHour,
              UserDefaults.standard.string(forKey: Self.morningShownKey) != today else { return }
        UserDefaults.standard.set(today, forKey: Self.morningShownKey)
        guard let latest = Self.recentSummaries(days: 7, maxCharsPerDay: .max, now: now).first else { return }
        let tasks = Self.openTasks(in: latest.text)
        guard !tasks.isEmpty else { return }
        let page = summaryDir.appendingPathComponent("\(latest.day).html")
        onMorningTasks?(tasks, page)
    }

    // MARK: - Week in review

    /// Sunday, 9am: the week that ended last night, written from its daily
    /// summaries rather than the raw logs -- seven short files, not a week of
    /// samples, so it costs one ordinary agent run.
    private static let weekFire = DateComponents(hour: 9, minute: 0, second: 0, weekday: 1)
    private var weekGeneration = 0
    private var weekRunning = false

    static var weekDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/nikxel/weekly", isDirectory: true)
    }

    private func scheduleWeek() {
        weekGeneration += 1
        let generation = weekGeneration
        guard let fire = Calendar.current.nextDate(after: Date(), matching: Self.weekFire, matchingPolicy: .nextTime) else { return }
        DispatchQueue.main.asyncAfter(wallDeadline: .now() + max(1, fire.timeIntervalSinceNow)) { [weak self] in
            guard let self = self, generation == self.weekGeneration else { return }
            self.generateWeek(endingBefore: fire)
            self.scheduleWeek()
        }
    }

    /// The last Sunday 9am that has passed, if its week was never written
    /// (the Mac was off or asleep through Sunday morning). Only until Tuesday
    /// morning: by midweek, last week's review is noise.
    private func weekBackfill() {
        guard let last = Calendar.current.nextDate(after: Date(), matching: Self.weekFire,
                                                   matchingPolicy: .nextTime, direction: .backward),
              Date().timeIntervalSince(last) < 2 * 86_400,
              !FileManager.default.fileExists(atPath: weekFileURL(for: last).path) else { return }
        generateWeek(endingBefore: last)
    }

    func generateWeekNow() {
        generateWeek(endingBefore: Date(), force: true)
    }

    private func weekFileURL(for sunday: Date) -> URL {
        Self.weekDirectory.appendingPathComponent("\(Self.dayKey(sunday)).md")
    }

    /// `end` is the morning it's written; the week is the seven days before.
    private func generateWeek(endingBefore end: Date, force: Bool = false) {
        guard !weekRunning else { return }
        weekRunning = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            defer { DispatchQueue.main.async { self.weekRunning = false } }
            let days = Self.recentSummaries(days: 7, maxCharsPerDay: 6000, now: end).reversed()
            // A fresh install has nothing to look back on; a backfill with no
            // days would otherwise retry on every wake.
            guard !days.isEmpty || force else { return }
            if days.isEmpty {
                DispatchQueue.main.async { NikxelView.tell(icon: "☀️", title: "No week to sum up yet", lines: ["The week in review is written from the daily summaries, and there are none for the last seven days."]) }
                return
            }
            let stats = self.weekStats(end: end)
            do {
                let report = days.map { "### \($0.day)\n\($0.text)" }.joined(separator: "\n\n")
                let output = try self.momGenerator.runPrompt(self.weekPrompt(report: report, sunday: end), kind: "weekly-summary")
                try? FileManager.default.createDirectory(at: Self.weekDirectory, withIntermediateDirectories: true)
                let fileURL = self.weekFileURL(for: end)
                try output.write(to: fileURL, atomically: true, encoding: .utf8)
                let pageURL = fileURL.deletingPathExtension().appendingPathExtension("html")
                try DayPage.html(from: output, stats: stats, morning: true).write(to: pageURL, atomically: true, encoding: .utf8)
                let line = Self.digestLine(stats) ?? "\(days.count) day\(days.count == 1 ? "" : "s") summed up"
                DispatchQueue.main.async { self.onWeekReady?(line, pageURL) }
            } catch {
                NSLog("DayLogger: week summary failed: \(error)")
            }
        }
    }

    private func weekPrompt(report: String, sunday: Date) -> String {
        let day = Self.dayKey(sunday)
        return """
You are writing the user's week in review, read on Sunday morning. Below are the end-of-day summaries Nikxel wrote for each day of the past week (some days may be missing -- the Mac was off). They are your only source.

\(NikxelSettings.languageInstruction)
\(roleGuidance().isEmpty ? "" : "\n\(roleGuidance())\n")\(NikxelSettings.userContextBlock.isEmpty ? "" : "\n\(NikxelSettings.userContextBlock)\n")
Write it warm, specific and short enough to read over coffee. Not "worked on several projects" but "shipped the Datacap certification fixes for Produce POS and got the car-wash invoice bug to prod".

Output this exact Markdown structure:

# \(day) — Week in review

## Summary
2-3 sentences: the shape of the week -- what it was mostly about, the biggest win, and how it felt (steady, scattered, a crunch).

## Highlights
- 3-6 bullets: the things worth remembering -- shipped work, decisions, milestones. Name the day in each ("Tue:").

## What you worked on
- One bullet per project, biggest first: what moved this week and where it stands now. Indent 1-3 sub-bullets for detail.

## Meetings
- The meetings that mattered, one bullet each: "<Day>: <who/what> — <outcome>". Skip routine stand-ups unless something came out of them. If none, write "- None this week."

## Open tasks
- Things people asked of the user during the week (WhatsApp, Slack, meetings) that the daily summaries left open or unclear and that no later day shows done. End each with " — open" or " — unclear". If none, write "- Nothing left open."

## Patterns
- 2-4 observations from across the days: when focus was best, what kept interrupting, late nights, a day that got lost. Only what the summaries support.

## Next week
- 2-4 suggestions that follow from the open tasks and in-flight work. Concrete, not motivational.

Rules:
- Never invent anything not in the daily summaries. Keep who-asked-whom exactly as the daily summaries have it.
- Output ONLY the Markdown — no preamble, no closing remarks.

---
DAILY SUMMARIES:
\(report)
"""
    }

    // MARK: - Aggregation

    private func generateSummary(for date: Date) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            let report = self.buildReport(for: date)
            if report.isEmpty { return }
            do {
                let prompt = self.summaryPrompt(report: report, date: date)
                let output = TwinProfile.correct(try self.momGenerator.runPrompt(prompt, kind: "daily-summary"))
                let fileURL = self.summaryFileURL(for: date)
                try output.write(to: fileURL, atomically: true, encoding: .utf8)
                // The .md stays: it's what the WhatsApp bot's memory reads back.
                let stats = self.dayStats(for: date)
                let pageURL = fileURL.deletingPathExtension().appendingPathExtension("html")
                try DayPage.html(from: output, stats: stats, daily: true).write(to: pageURL, atomically: true, encoding: .utf8)
                if let line = Self.digestLine(stats) {
                    DispatchQueue.main.async { self.onSummaryReady?(line, pageURL) }
                }
                TwinDistiller.distill(meetingSelfLines: [], sentMessages: TwinProfile.recentSentMessages(),
                                      daySummary: output, runPrompt: { try self.momGenerator.runPrompt($0, kind: $1) })
                // Fold the day's ERP picture into the sealed profile too (skips if not connected).
                ErpCrawl.ingest(runPrompt: { try self.momGenerator.runPrompt($0, kind: $1) })
            } catch {
                NSLog("DayLogger: summary generation failed: \(error)")
            }
        }
    }

    private func buildReport(for date: Date) -> String {
        var parts: [String] = []
        if let usage = aggregateAppUsage(for: date), !usage.isEmpty {
            parts.append("## App usage (sampled every 15s)\n" + usage)
        }
        let meetings = aggregateMeetings(for: date)
        if !meetings.isEmpty { parts.append("## Meetings\n" + meetings) }
        let git = aggregateGit(for: date)
        if !git.isEmpty { parts.append("## Git activity\n" + git) }
        let claudePrompts = aggregateClaudeSessions(for: date)
        if !claudePrompts.isEmpty { parts.append("## Claude Code sessions (your prompts today)\n" + claudePrompts) }
        let opencodePrompts = aggregateOpencodeSessions(for: date)
        if !opencodePrompts.isEmpty { parts.append("## Opencode sessions (your prompts today)\n" + opencodePrompts) }
        let waChats = aggregateWhatsAppChats(for: date)
        if !waChats.isEmpty { parts.append("## WhatsApp chats (preview snapshots through the day)\n" + waChats) }
        let waCalls = aggregateWhatsAppCalls(for: date)
        if !waCalls.isEmpty { parts.append("## WhatsApp calls\n" + waCalls) }
        if let prev = Self.recentSummaries(days: 7, maxCharsPerDay: .max, now: date).first {
            let open = Self.openTasks(in: prev.text)
            if !open.isEmpty {
                parts.append("## Still open from before (from the \(prev.day) summary)\n" + open.map { "- " + $0 }.joined(separator: "\n"))
            }
        }
        let slack = Slack.messages(on: Self.dayKey(date))
        if !slack.isEmpty { parts.append("## Slack messages\n" + slack.joined(separator: "\n")) }
        return parts.joined(separator: "\n\n")
    }

    private func aggregateAppUsage(for date: Date) -> String? {
        struct Sample { let t: TimeInterval; let app: String; let title: String }
        let url = logFileURL(for: date)
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        var samples: [Sample] = []
        for line in content.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let t = obj["t"] as? TimeInterval,
                  let app = obj["app"] as? String,
                  let title = obj["title"] as? String else { continue }
            samples.append(Sample(t: t, app: app, title: title))
        }
        if samples.isEmpty { return nil }
        samples.sort { $0.t < $1.t }

        var appDurations: [String: TimeInterval] = [:]
        var appTitles: [String: [String: TimeInterval]] = [:]
        for i in samples.indices {
            let dur: TimeInterval
            if i + 1 < samples.count {
                dur = min(samples[i+1].t - samples[i].t, durationCap)
            } else {
                dur = sampleInterval
            }
            appDurations[samples[i].app, default: 0] += dur
            if !samples[i].title.isEmpty {
                appTitles[samples[i].app, default: [:]][samples[i].title, default: 0] += dur
            }
        }

        var lines: [String] = []
        for (app, dur) in appDurations.sorted(by: { $0.value > $1.value }) {
            let mins = Int(dur / 60)
            if mins < 1 { continue }
            lines.append("- \(app): \(mins) min")
            if let titles = appTitles[app] {
                let top = titles.sorted(by: { $0.value > $1.value }).prefix(3)
                for (title, td) in top {
                    let tm = Int(td / 60)
                    if tm < 1 { continue }
                    lines.append("  - \"\(title)\" (\(tm) min)")
                }
            }
        }
        return lines.joined(separator: "\n")
    }

    private func aggregateMeetings(for date: Date) -> String {
        guard let files = try? FileManager.default.contentsOfDirectory(at: meetingsDir, includingPropertiesForKeys: nil) else { return "" }
        let prefix = Self.dayKey(date)
        let today = files.filter { $0.lastPathComponent.hasPrefix(prefix) && $0.pathExtension == "md" }
                         .sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
        if today.isEmpty { return "" }
        var lines: [String] = []
        for f in today {
            let stem = f.deletingPathExtension().lastPathComponent
            // Stem format: yyyy-MM-dd-HHmmss
            let comps = stem.split(separator: "-")
            let time: String
            if comps.count == 4, comps[3].count == 6 {
                let s = comps[3]
                let hh = s.prefix(2)
                let mm = s.dropFirst(2).prefix(2)
                time = "\(hh):\(mm)"
            } else {
                time = "?"
            }
            // Pull the Summary section out of the MOM, if present, to give the LLM something to anchor on.
            var blurb = ""
            if let content = try? String(contentsOf: f, encoding: .utf8) {
                blurb = extractSection(content, heading: "Summary") ?? ""
            }
            if blurb.isEmpty {
                lines.append("- \(time) — \(f.lastPathComponent)")
            } else {
                lines.append("- \(time) — \(f.lastPathComponent)\n  \(blurb.replacingOccurrences(of: "\n", with: "\n  "))")
            }
        }
        return lines.joined(separator: "\n")
    }

    private func extractSection(_ markdown: String, heading: String) -> String? {
        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false)
        var capturing = false
        var out: [String] = []
        for line in lines {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("## ") {
                if capturing { break }
                if t.dropFirst(3).trimmingCharacters(in: .whitespaces) == heading { capturing = true; continue }
            } else if capturing {
                out.append(String(line))
            }
        }
        let joined = out.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return joined.isEmpty ? nil : joined
    }

    /// Directory names never worth walking into when hunting for repos. Without
    /// this the scan descends every `node_modules` in full -- hundreds of
    /// thousands of files across a handful of JS projects -- and surfaces
    /// vendored `.git` directories as if they were the user's own work.
    static let skipWhileScanning: Set<String> = [
        "node_modules", "Pods", "DerivedData", "vendor", "target",
        "build", "dist", ".build", ".next", ".nuxt", ".cache",
        "venv", ".venv", "__pycache__", "Library", "Applications",
    ]

    private var reposCache: (root: String, repos: [URL], at: Date)?

    /// The tree walk is the slow half of every git pass, and new clones are
    /// rare: an hour-old list is fine.
    private func findRepos() -> [URL] {
        let root = NikxelSettings.projectsRoot
        if let c = reposCache, c.root == root, Date().timeIntervalSince(c.at) < 3600 { return c.repos }
        let repos = scanRepos()
        reposCache = (root, repos, Date())
        return repos
    }

    private func scanRepos() -> [URL] {
        var repoDirs: [URL] = []
        // Not .skipsHiddenFiles: `.git` is itself hidden, so that option made
        // this scan find no repos at all. Other dot-dirs are skipped by hand.
        if let enumerator = FileManager.default.enumerator(at: scanRoot, includingPropertiesForKeys: [.isDirectoryKey]) {
            for case let url as URL in enumerator {
                let name = url.lastPathComponent
                if name == ".git" {
                    repoDirs.append(url.deletingLastPathComponent())
                    enumerator.skipDescendants()
                } else if name.hasPrefix(".") || Self.skipWhileScanning.contains(name) {
                    enumerator.skipDescendants()
                }
            }
        }
        if repoDirs.isEmpty {
            // Distinguishable in the log from "found repos, nothing happened
            // today". An empty scan usually means one of two things: the root
            // is wrong (see `projectsRoot`), or macOS is refusing to let
            // Nikxel list that folder -- System Settings -> Privacy & Security
            // -> Files and Folders.
            cblog("DayLogger: no git repos under \(scanRoot.path) — check projectsRoot, or Nikxel's access to that folder in System Settings")
        } else {
            cblog("DayLogger: scanned \(scanRoot.path) — \(repoDirs.count) repo(s)")
        }
        return repoDirs
    }

    /// Repos committed to in the last `days` days, quiet today or not: the
    /// current branch, the branches most recently worked on, and the last few
    /// commits. Today's git activity alone can't answer "any update on the
    /// Datacap task?" when that work sat on a branch two days ago.
    private func recentWork(repos: [URL], days: Int) -> String {
        var blocks = [String](repeating: "", count: repos.count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: repos.count) { i in
            let repo = repos[i]
            let commits = runGit(repo: repo, args: ["log", "--branches", "--remotes", "-6", "--since=\(days).days", "--pretty=format:%cr: %s"])
            guard !commits.isEmpty else { return }
            let branch = runGit(repo: repo, args: ["branch", "--show-current"])
            let branches = runGit(repo: repo, args: ["for-each-ref", "--sort=-committerdate", "--count=4",
                                                     "--format=%(refname:short)", "refs/heads"])
                .split(separator: "\n").joined(separator: ", ")
            let block = "### \(repo.lastPathComponent) (on \(branch.isEmpty ? "?" : branch); recent branches: \(branches))\n"
                + commits.split(separator: "\n").map { "  " + $0 }.joined(separator: "\n")
            lock.lock(); blocks[i] = block; lock.unlock()
        }
        return blocks.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    /// Files that churn without being anyone's work.
    static func isNoiseFile(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        return name == ".DS_Store" || name.hasSuffix(".lock") || name.hasSuffix("-lock.json")
            || name == "pnpm-lock.yaml" || name == "yarn.lock"
    }

    /// The function or block a `git diff` hunk sits in, from its `@@` header:
    /// `@@ -1,2 +1,3 @@ export function buildSaleBody(` -> `export function buildSaleBody(`.
    static func hunkContexts(_ diff: String, limit: Int = 4) -> [String] {
        var out: [String] = []
        for line in diff.split(separator: "\n") where line.hasPrefix("@@") {
            let parts = line.components(separatedBy: "@@")
            guard parts.count >= 3 else { continue }
            let ctx = parts[2...].joined(separator: "@@").trimmingCharacters(in: .whitespaces)
            if !ctx.isEmpty && !out.contains(ctx) { out.append(String(ctx.prefix(80))) }
            if out.count == limit { break }
        }
        return out
    }

    /// For the bot: what was actually worked on today, per repo -- commits
    /// since midnight, and uncommitted files whose modification time is today
    /// (a raw `git status` also lists week-old leftovers and lockfiles), each
    /// with the functions its diff touches. Repos sort by latest edit, so the
    /// thing in hand right now is what survives the prompt cap.
    private func todaysEdits(repos: [URL]) -> String {
        let dayStart = Calendar.current.startOfDay(for: Date())
        var blocks = [(latest: Date, text: String)?](repeating: nil, count: repos.count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: repos.count) { i in
            let repo = repos[i]
            // Every branch, local and remote: work committed and pushed from a
            // branch other than the checked-out one is still today's work.
            let commits = runGit(repo: repo, args: ["log", "--branches", "--remotes", "--since=midnight",
                                                    "--pretty=format:%ct %h %s"])
            var files: [(at: Date, path: String)] = []
            for line in runGit(repo: repo, args: ["status", "--porcelain", "--untracked-files=all"])
                .split(separator: "\n") where line.count > 3 {
                let raw = String(line.dropFirst(3))
                let path = raw.components(separatedBy: " -> ").last ?? raw
                guard !Self.isNoiseFile(path),
                      let m = (try? repo.appendingPathComponent(path)
                        .resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                      m >= dayStart else { continue }
                files.append((m, path))
            }
            guard !commits.isEmpty || !files.isEmpty else { return }
            files.sort { $0.at > $1.at }
            let commitLines = commits.split(separator: "\n").map { String($0) }
            let lastCommit = commitLines.first.flatMap { Double($0.split(separator: " ").first ?? "") }
                .map { Date(timeIntervalSince1970: $0) } ?? dayStart
            let branch = runGit(repo: repo, args: ["branch", "--show-current"])
            var out = ["### \(repo.lastPathComponent) (on \(branch.isEmpty ? "?" : branch))"]
            if !commitLines.isEmpty {
                out.append("Committed today (newest first):")
                for line in commitLines.prefix(8) {
                    let hashAndSubject = line.split(separator: " ", maxSplits: 1).dropFirst().joined()
                    let hash = String(hashAndSubject.prefix { $0 != " " })
                    let remotes = runGit(repo: repo, args: ["branch", "-r", "--contains", hash,
                                                            "--format=%(refname:short)"])
                        .split(separator: "\n").filter { !$0.hasSuffix("/HEAD") }
                    out.append("  " + hashAndSubject + (remotes.isEmpty ? " — local only, not pushed"
                                                                       : " — pushed to " + remotes.prefix(3).joined(separator: ", ")))
                }
            }
            if !files.isEmpty {
                let t = DateFormatter(); t.dateFormat = "HH:mm"
                out.append("Edited today, not committed yet (newest first):")
                for f in files.prefix(8) {
                    let ctx = Self.hunkContexts(runGit(repo: repo, args: ["diff", "-U0", "HEAD", "--", f.path]))
                    out.append("  [\(t.string(from: f.at))] \(f.path)" + (ctx.isEmpty ? "" : " — in: " + ctx.joined(separator: "; ")))
                }
                if files.count > 8 { out.append("  …and \(files.count - 8) more") }
            }
            let latest = max(files.first?.at ?? dayStart, lastCommit)
            lock.lock(); blocks[i] = (latest, out.joined(separator: "\n")); lock.unlock()
        }
        return blocks.compactMap { $0 }.sorted { $0.latest > $1.latest }.map(\.text).joined(separator: "\n")
    }

    private func aggregateGit(for date: Date) -> String {
        let repoDirs = findRepos()
        guard !repoDirs.isEmpty else { return "" }
        let day = Self.dayKey(date)
        // One block per repo, filled concurrently: serially, ~30 repos of git
        // calls took ~12s, which a WhatsApp reply was waiting on.
        var blocks = [[String]](repeating: [], count: repoDirs.count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: repoDirs.count) { i in
            let repo = repoDirs[i]
            var lines: [String] = []
            defer { lock.lock(); blocks[i] = lines; lock.unlock() }
            let commits = runGit(repo: repo, args: ["log",
                                                    "--since=\(day) 00:00:00",
                                                    "--until=\(day) 23:59:59",
                                                    "--shortstat",
                                                    "--pretty=format:%h %s"])
            // Uncommitted work: tracked changes (working tree vs HEAD) + untracked files.
            // Captures in-flight features the user hasn't pushed/committed yet.
            let status = runGit(repo: repo, args: ["status", "--short"])
            // Idle repo: stop at two git calls rather than five.
            if commits.isEmpty && status.isEmpty { return }
            let uncommitted = runGit(repo: repo, args: ["diff", "--shortstat", "HEAD"])
            let branch = runGit(repo: repo, args: ["branch", "--show-current"])
            // Recent commit messages give the LLM context on what feature line is currently active.
            let recent = runGit(repo: repo, args: ["log", "-5", "--pretty=format:%h %s"])
            lines.append("### \(repo.lastPathComponent)")
            if !branch.isEmpty { lines.append("On branch: \(branch)") }
            if !commits.isEmpty {
                lines.append("Committed today:")
                lines.append(commits)
            }
            if !uncommitted.isEmpty || !status.isEmpty {
                lines.append("Uncommitted right now:")
                if !uncommitted.isEmpty { lines.append(uncommitted) }
                if !status.isEmpty { lines.append(status) }
            }
            if !recent.isEmpty {
                lines.append("Recent commits (for context, may be older than today):")
                lines.append(recent)
            }
        }
        return blocks.joined().joined(separator: "\n")
    }

    // MARK: - Claude Code session prompts

    private func aggregateClaudeSessions(for date: Date) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let projectsDir = home.appendingPathComponent(".claude/projects", isDirectory: true)
        guard let projects = try? FileManager.default.contentsOfDirectory(at: projectsDir, includingPropertiesForKeys: nil) else { return "" }
        let cal = Calendar.current
        let dayStart = cal.startOfDay(for: date)
        let dayEnd = cal.date(byAdding: .day, value: 1, to: dayStart) ?? date
        let isoFmt = ISO8601DateFormatter()
        isoFmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoFmtNoFrac = ISO8601DateFormatter()
        isoFmtNoFrac.formatOptions = [.withInternetDateTime]
        let timeFmt = DateFormatter()
        timeFmt.dateFormat = "HH:mm"

        struct Prompt { let ts: Date; let project: String; let text: String }
        var prompts: [Prompt] = []

        for projDir in projects where projDir.hasDirectoryPath {
            let projectName = humanizeClaudeProjectDir(projDir.lastPathComponent)
            // Nikxel's own agent runs (chat replies, summaries) from before they
            // stopped being saved -- prompts Nikxel wrote, not the user.
            if projDir.lastPathComponent.contains("nikxel-momworkspace") { continue }
            guard let sessions = try? FileManager.default.contentsOfDirectory(at: projDir, includingPropertiesForKeys: nil) else { continue }
            for session in sessions where session.pathExtension == "jsonl" {
                let modified = (try? session.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                if let m = modified, m < dayStart { continue }
                guard let content = try? String(contentsOf: session, encoding: .utf8) else { continue }
                for line in content.split(separator: "\n", omittingEmptySubsequences: true) {
                    // Cheap prefilter: most bytes are assistant and tool lines,
                    // and JSON-parsing them all took ~10s on a busy day.
                    guard line.contains("\"type\":\"user\"") else { continue }
                    guard let data = line.data(using: .utf8),
                          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                    guard (obj["type"] as? String) == "user" else { continue }
                    if (obj["isMeta"] as? Bool) == true { continue }
                    guard let msg = obj["message"] as? [String: Any],
                          let raw = msg["content"] as? String else { continue }
                    // Filter slash commands, system reminders, and tool-result chunks.
                    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.hasPrefix("<command-name>") { continue }
                    if trimmed.hasPrefix("<local-command-") { continue }
                    if trimmed.hasPrefix("<system-reminder>") { continue }
                    if trimmed.isEmpty { continue }
                    guard let tsStr = obj["timestamp"] as? String,
                          let ts = isoFmt.date(from: tsStr) ?? isoFmtNoFrac.date(from: tsStr) else { continue }
                    if ts < dayStart || ts >= dayEnd { continue }
                    prompts.append(Prompt(ts: ts, project: projectName, text: trimmed))
                }
            }
        }

        if prompts.isEmpty { return "" }
        prompts.sort { $0.ts < $1.ts }
        // Cap each prompt to 300 chars so a single long paste doesn't blow the LLM context.
        // Cap total to 80 prompts so a heavy session day still fits.
        let capped = prompts.suffix(80)
        var lines: [String] = []
        for p in capped {
            let snippet = p.text.count > 300 ? String(p.text.prefix(300)) + "…" : p.text
            let oneLine = snippet.replacingOccurrences(of: "\n", with: " ")
            lines.append("- [\(timeFmt.string(from: p.ts))] (\(p.project)) \(oneLine)")
        }
        return lines.joined(separator: "\n")
    }

    private func humanizeClaudeProjectDir(_ raw: String) -> String {
        // Claude Code encodes cwds like "-Users-nikhildhanda-Desktop-everything-projects-nikxel".
        // Restore the last segment as the human project name.
        let parts = raw.split(separator: "-").map { String($0) }
        return parts.last ?? raw
    }

    // MARK: - Opencode session prompts

    private func aggregateOpencodeSessions(for date: Date) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let db = home.appendingPathComponent(".local/share/opencode/opencode.db")
        guard FileManager.default.fileExists(atPath: db.path) else { return "" }
        // Untouched since before that day (db and its WAL): nothing to find,
        // and a cold query over a ~1 GB db costs seconds.
        let dayStart = Calendar.current.startOfDay(for: date)
        let touched = [db, URL(fileURLWithPath: db.path + "-wal")].compactMap {
            (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        }.max()
        if let t = touched, t < dayStart { return "" }
        let day = Self.dayKey(date)
        // Cap each prompt to 300 chars, return time + text + session id (so the LLM can group by session).
        let query = """
        SELECT strftime('%H:%M', m.time_created/1000, 'unixepoch', 'localtime') AS hm,
               substr(m.session_id, 1, 12),
               substr(json_extract(p.data, '$.text'), 1, 300)
        FROM message m
        JOIN part p ON p.message_id = m.id
        WHERE json_extract(m.data, '$.role') = 'user'
          AND json_extract(p.data, '$.type') = 'text'
          AND date(m.time_created/1000, 'unixepoch', 'localtime') = '\(day)'
        ORDER BY m.time_created ASC
        LIMIT 80
        """

        let task = Process()
        task.launchPath = "/usr/bin/sqlite3"
        task.arguments = ["-separator", "\t", db.path, query]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do { try task.run() } catch { return "" }
        task.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let raw = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return "" }
        var lines: [String] = []
        for row in raw.split(separator: "\n") {
            let cols = row.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard cols.count == 3 else { continue }
            let oneLine = cols[2].replacingOccurrences(of: "\n", with: " ")
            lines.append("- [\(cols[0])] (ses \(cols[1])) \(oneLine)")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - WhatsApp

    private func aggregateWhatsAppChats(for date: Date) -> String {
        let entries = WhatsAppActivityLogger.readLog(file: "chats", for: date)
        if entries.isEmpty { return "" }
        let timeFmt = DateFormatter()
        timeFmt.dateFormat = "HH:mm"
        var lines: [String] = [], seen: Set<String> = []
        for e in entries {
            guard let t = e["t"] as? TimeInterval,
                  let name = e["name"] as? String,
                  let preview = e["preview"] as? String,
                  // A preview that flips back is the same message: say it once.
                  seen.insert(name + "\u{0}" + preview).inserted else { continue }
            let time = timeFmt.string(from: Date(timeIntervalSince1970: t))
            let oneLine = preview.replacingOccurrences(of: "\n", with: " ")
            lines.append("- [\(time)] \(name): \(oneLine)")
        }
        return lines.joined(separator: "\n")
    }

    private func aggregateWhatsAppCalls(for date: Date) -> String {
        let entries = WhatsAppActivityLogger.readLog(file: "calls", for: date)
        if entries.isEmpty { return "" }
        let timeFmt = DateFormatter()
        timeFmt.dateFormat = "HH:mm"
        var lines: [String] = []
        for e in entries {
            guard let t = e["t"] as? TimeInterval,
                  let name = e["name"] as? String else { continue }
            let info = (e["info"] as? String) ?? ""
            let waTime = (e["timeText"] as? String) ?? ""
            let seenAt = timeFmt.string(from: Date(timeIntervalSince1970: t))
            lines.append("- \(name) — \(info)\(waTime.isEmpty ? "" : " (\(waTime))") [seen \(seenAt)]")
        }
        return lines.joined(separator: "\n")
    }

    private func runGit(repo: URL, args: [String]) -> String {
        let task = Process()
        task.launchPath = "/usr/bin/git"
        task.arguments = ["-C", repo.path] + args
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do { try task.run() } catch { return "" }
        // Drain before waiting: a status listing past the 64 KB pipe buffer
        // would otherwise block git and this wait forever.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// Role-specific emphasis for the daily/weekly summary, taken from the
    /// chosen summary-template slug (the user's role, asked once). Empty for
    /// "default", which leaves the summary as the general-purpose journal.
    private func roleGuidance() -> String {
        switch NikxelSettings.summaryTemplate {
        case "developer":
            return "Shape this for a DEVELOPER. Make code the spine: lead with what was built, fixed or shipped, tied to the session prompts and Git (commits, files/lines changed, which repos and branches). Keep the technical specifics — bug causes, modules, endpoints. Meetings and chats are secondary."
        case "project-manager":
            return "Shape this for a PRODUCT / PROJECT MANAGER. Make people and progress the spine: lead with meetings — who was met, what was discussed, decisions and updates taken — and what moved or slipped on each project. Emphasize asks, owners and dates across WhatsApp/Slack/meetings. Keep code to a one-line \"shipped X\"."
        case "co-founder":
            return "Shape this for a CO-FOUNDER. Keep it high-level and decision-first: lead with the decisions, numbers and commitments that mattered, surface anything waiting on them, and record money figures exactly as stated. Be concise — skip routine app-usage and browsing detail unless it changed something."
        case "hr":
            return "Shape this for an HR / PEOPLE lead. Centre it on people: who was spoken with, hiring and people conversations, commitments made to candidates or staff, and follow-ups owed to people. Keep code and technical detail minimal."
        default:
            return ""
        }
    }

    private func summaryPrompt(report: String, date: Date) -> String {
        let day = Self.dayKey(date)
        return """
You are generating an end-of-day journal entry for the user, based on raw activity data captured throughout the day:
- Foreground app + window-title samples (every 15s) — shows what was on screen.
- Meetings they recorded today (with the MOM summaries).
- Git activity per project: commits today, uncommitted changes, current branch, recent commit history.
- Claude Code session prompts: the user's actual messages to Claude today, timestamped, with project name.
- Opencode session prompts: the user's actual messages to opencode today, timestamped.
- Still open from before: the open-task list from the previous summary, carried forward (may be absent).
- WhatsApp chats: periodic preview-text snapshots of each chat through the day (name + a short text excerpt), NOT full conversations.
  Who wrote each line: "<chat>: You: …" is a message the USER sent to that chat. "<chat>: <Sender>: …" in a group is from that sender. A line with no sender in a one-to-one chat is from the contact the chat is named after. Never flip these: a "You:" line is the user asking or telling the other person, not the other way round.
- WhatsApp calls: call-log entries (caller, missed/incoming/outgoing, WhatsApp's own time label) — no call content/audio is available unless that call happened to be recorded as a meeting (in which case it shows up under Meetings too).
- Slack messages: the day's messages from channels and DMs the user can see (channel or "DM", sender, text). Their own messages appear under their own Slack name.

The session prompts are the most informative signal: they tell you LITERALLY what bug or feature the user was working on, in their own words. Use them as the spine of the narrative.

For WhatsApp chats and Slack messages: look for signs a task/ask was assigned to the user in a message ("can you...", "please...", "need you to...", a deadline, a request) and note who sent it and what it was. Only flag it as "done" if there's later evidence in the same data (a reply, a relevant commit, a later message) that it was acted on — otherwise mark it open/unclear. Don't force a task interpretation onto ordinary chit-chat.

\(NikxelSettings.languageInstruction)
\(roleGuidance().isEmpty ? "" : "\n\(roleGuidance())\n")\(NikxelSettings.userContextBlock.isEmpty ? "" : "\n\(NikxelSettings.userContextBlock)\n")
Write a friendly, personal, specific narrative. Not generic ("worked on coding") but specific ("fixed the typing-animation lag bug in Nikxel — diagnosed it as a missing CGEventTap re-enable, then added day-of-week logging").

Date: \(day)

Output this exact Markdown structure:

# \(day) — Day in review

## Summary
2-4 sentences capturing the overall shape of the day: which projects dominated, what specific features/bugs you worked on (use the session-prompt data!), what kind of day it was.

## What you worked on
- Per-feature/bug bullets. Anchor each one to a real ask from the session prompts when possible: "Fixed the typing-linger bug (asked at ~3pm, shipped commit abc123, ~50 line diff)." Group related prompts into one bullet — don't list every prompt verbatim.
- Note both shipped work (commits) and in-flight work (uncommitted diff).

## Meetings
- One bullet per meeting: time, who/what (use the MOM summary if present), key outcome if obvious.
- If none, write "- None today."

## WhatsApp
- Calls: one bullet per call (who, missed/incoming/outgoing, when). If none, write "- No calls today."
- Tasks assigned in chats: one bullet per task you can identify — "<Who> asked you to <what> (~<time>) — <done/open/unclear>". If none, write "- No tasks assigned today."
- Anything else notable from chats worth a quick mention. If nothing, write "- Nothing else notable."

## Slack
- Only if there is a "Slack messages" section in the data; otherwise leave this whole section out.
- Tasks asked of you: one bullet per task — "<Who> asked you to <what> in <#channel or DM> (~<time>) — <done/open/unclear>". If none, write "- No tasks assigned today."
- The main threads or decisions in channels you took part in, briefly. Skip channel chatter you weren't part of.

## Open tasks
- The running list of everything still owed: each item from "Still open from before" UNLESS today's data shows it done (a reply, a commit, a message saying it's done) -- then drop it -- plus every task asked of the user today (WhatsApp, Slack, meetings) that isn't done yet.
- One bullet each: "<what> — for <who> (asked <weekday or date>) — open". Use "— unclear" instead when you can't tell. Keep the original asked-date for carried items.
- Only things asked of the user. Never list something the user asked someone else to do.
- If nothing is open, write "- Nothing open."

## Browsing & Reading
- Time in browser/reading apps, summarized ("~45 min in Chrome — mostly docs"). Don't list every URL.

## Other
- Anything else worth flagging: long focus blocks, fragmented mornings, unusual late-night activity, repeated context switches, etc.

Rules:
- Never invent activity not in the data. Inferring is OK ("session prompts mention 'typing lag' and you committed to StateMachine.swift, so you were fixing the typing bug") — flag uncertain inferences.
- When session prompts and git activity disagree, prefer what the session prompts say the user was trying to do.
- Start every top-level bullet in What you worked on, Meetings, Browsing & Reading and Other with one tag from [coding] [shipped] [meeting] [research] [learning] [writing] [review] [planning] [comms] [other], e.g. `- [research] Compared three OCR libraries…`. Pick [shipped] for a push, release or deploy.
- Output ONLY the Markdown — no preamble, no closing remarks.

---
RAW ACTIVITY DATA:
\(report)
"""
    }
}
