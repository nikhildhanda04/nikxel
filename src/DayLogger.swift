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
    private var summaryTimer: Timer?
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
        backfillIfMissed()
    }

    func stop() {
        sampleTimer?.invalidate(); sampleTimer = nil
        summaryTimer?.invalidate(); summaryTimer = nil
    }

    func generateSummaryNow() {
        generateSummary(for: Date())
    }

    /// Fired on the main thread right after an end-of-day summary is written,
    /// with the one-line digest for the avatar bubble and the file it came from.
    var onSummaryReady: ((String, URL) -> Void)?

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
    static func humanDuration(minutes: Int) -> String {
        let h = minutes / 60, m = minutes % 60
        if h == 0 { return "\(m)m" }
        if m == 0 { return "\(h)h" }
        return "\(h)h \(m)m"
    }

    /// Counts today's coding time, meetings and WhatsApp messages off the same
    /// logs the narrative summary is built from.
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

        stats.messages = WhatsAppActivityLogger.readLog(file: "chats", for: date).count

        return stats
    }

    // MARK: - Live context

    private var liveCache: (text: String, at: Date, inMeeting: Bool)?
    /// `aggregateGit` shells out to git once per repo under ~/Desktop, and a
    /// busy chat can ask for this several times a minute. Two minutes is well
    /// inside "what are you working on right now".
    private let liveCacheTTL: TimeInterval = 120

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

        let git = aggregateGit(for: Date())
        if !git.isEmpty {
            lines.append("- Code today:\n" + git.split(separator: "\n")
                .prefix(14).map { "  " + $0 }.joined(separator: "\n"))
        }

        let text = lines.joined(separator: "\n")
        liveCache = (text, Date(), inMeeting)
        return text
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

    private static func dayKey(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        return fmt.string(from: date)
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

    private func scheduleSummary() {
        summaryTimer?.invalidate()
        let fire = nextSummaryFireDate(after: Date())
        let interval = max(1, fire.timeIntervalSinceNow)
        summaryTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            self.generateSummary(for: Date())
            self.scheduleSummary()
        }
    }

    /// Idempotent: writes today's summary if past the summary hour and the
    /// file isn't there yet. Safe to call from app launch, wake-from-sleep,
    /// and external triggers (LaunchAgent).
    func backfillIfMissed() {
        let now = Date()
        let cal = Calendar.current
        var comps = cal.dateComponents([.year, .month, .day], from: now)
        comps.hour = summaryHour; comps.minute = 0; comps.second = 0
        guard let todayFire = cal.date(from: comps), now >= todayFire else { return }
        if FileManager.default.fileExists(atPath: summaryFileURL(for: now).path) { return }
        generateSummary(for: now)
    }

    // MARK: - Aggregation

    private func generateSummary(for date: Date) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            let report = self.buildReport(for: date)
            if report.isEmpty { return }
            do {
                let prompt = self.summaryPrompt(report: report, date: date)
                let output = try self.momGenerator.runPrompt(prompt)
                let fileURL = self.summaryFileURL(for: date)
                try output.write(to: fileURL, atomically: true, encoding: .utf8)
                if let line = Self.digestLine(self.dayStats(for: date)) {
                    DispatchQueue.main.async { self.onSummaryReady?(line, fileURL) }
                }
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

    private func aggregateGit(for date: Date) -> String {
        var repoDirs: [URL] = []
        if let enumerator = FileManager.default.enumerator(at: scanRoot, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
            for case let url as URL in enumerator {
                let name = url.lastPathComponent
                if name == ".git" {
                    repoDirs.append(url.deletingLastPathComponent())
                    enumerator.skipDescendants()
                } else if Self.skipWhileScanning.contains(name) {
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
            return ""
        }
        cblog("DayLogger: scanned \(scanRoot.path) — \(repoDirs.count) repo(s)")
        let day = Self.dayKey(date)
        var lines: [String] = []
        for repo in repoDirs {
            let commits = runGit(repo: repo, args: ["log",
                                                    "--since=\(day) 00:00:00",
                                                    "--until=\(day) 23:59:59",
                                                    "--shortstat",
                                                    "--pretty=format:%h %s"])
            // Uncommitted work: tracked changes (working tree vs HEAD) + untracked files.
            // Captures in-flight features the user hasn't pushed/committed yet.
            let uncommitted = runGit(repo: repo, args: ["diff", "--shortstat", "HEAD"])
            let status = runGit(repo: repo, args: ["status", "--short"])
            let branch = runGit(repo: repo, args: ["branch", "--show-current"])
            // Recent commit messages give the LLM context on what feature line is currently active.
            let recent = runGit(repo: repo, args: ["log", "-5", "--pretty=format:%h %s"])
            if commits.isEmpty && uncommitted.isEmpty && status.isEmpty { continue }
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
        return lines.joined(separator: "\n")
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
            guard let sessions = try? FileManager.default.contentsOfDirectory(at: projDir, includingPropertiesForKeys: nil) else { continue }
            for session in sessions where session.pathExtension == "jsonl" {
                guard let content = try? String(contentsOf: session, encoding: .utf8) else { continue }
                for line in content.split(separator: "\n", omittingEmptySubsequences: true) {
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
        var lines: [String] = []
        for e in entries {
            guard let t = e["t"] as? TimeInterval,
                  let name = e["name"] as? String,
                  let preview = e["preview"] as? String else { continue }
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
        task.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
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
- WhatsApp chats: periodic preview-text snapshots of each chat through the day (name + a short text excerpt), NOT full conversations.
- WhatsApp calls: call-log entries (caller, missed/incoming/outgoing, WhatsApp's own time label) — no call content/audio is available unless that call happened to be recorded as a meeting (in which case it shows up under Meetings too).

The session prompts are the most informative signal: they tell you LITERALLY what bug or feature the user was working on, in their own words. Use them as the spine of the narrative.

For WhatsApp chats specifically: look for signs a task/ask was assigned to the user in a message ("can you...", "please...", "need you to...", a deadline, a request) and note who sent it and what it was. Only flag it as "done" if there's later evidence in the same data (a reply, a relevant commit, a later message) that it was acted on — otherwise mark it open/unclear. Don't force a task interpretation onto ordinary chit-chat.

\(NikxelSettings.languageInstruction)

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

## Browsing & Reading
- Time in browser/reading apps, summarized ("~45 min in Chrome — mostly docs"). Don't list every URL.

## Other
- Anything else worth flagging: long focus blocks, fragmented mornings, unusual late-night activity, repeated context switches, etc.

Rules:
- Never invent activity not in the data. Inferring is OK ("session prompts mention 'typing lag' and you committed to StateMachine.swift, so you were fixing the typing bug") — flag uncertain inferences.
- When session prompts and git activity disagree, prefer what the session prompts say the user was trying to do.
- Output ONLY the Markdown — no preamble, no closing remarks.

---
RAW ACTIVITY DATA:
\(report)
"""
    }
}
