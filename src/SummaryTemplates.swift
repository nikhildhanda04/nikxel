import Foundation

/// Role-shaped summary templates, living as plain text files in
/// `~/.nikxel/templates/`.
///
/// A template is nothing more than a named `summary_style.txt`: a list of plain
/// instructions that gets injected into the prompt as `{{custom_instructions}}`
/// and overrides the built-in structure. Everything here is file management
/// around that one existing mechanism -- there is no second prompt engine, and
/// a template never carries a copy of the speaker-separation rules, so
/// templates keep working when those rules are improved.
///
/// A developer, an HR lead, a PM and a founder want genuinely different things
/// out of the same call, which is why the shipped set is by role rather than by
/// format. All of them are editable, and anyone can add their own.
enum SummaryTemplates {

    static let templatesDir: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".nikxel/templates", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static func url(for slug: String) -> URL {
        templatesDir.appendingPathComponent("\(slug).txt")
    }

    static var activeURL: URL { url(for: NikxelSettings.summaryTemplate) }

    // MARK: - Reading

    /// The instructions in `slug`, with `#` comment lines stripped. Empty when
    /// the file is missing, blank, or all comments -- which is what "default"
    /// is, and why selecting it changes nothing about the shipped prompt.
    static func instructions(in slug: String) -> String {
        guard let raw = try? String(contentsOf: url(for: slug), encoding: .utf8) else { return "" }
        return raw.components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static var activeInstructions: String { instructions(in: NikxelSettings.summaryTemplate) }

    // MARK: - Listing

    /// Every template on disk, shipped ones first in their listed order, then
    /// anything the user added, alphabetically.
    static func available() -> [(slug: String, name: String)] {
        seedIfMissing()
        let fm = FileManager.default
        let found = ((try? fm.contentsOfDirectory(atPath: templatesDir.path)) ?? [])
            .filter { $0.hasSuffix(".txt") }
            .map { String($0.dropLast(4)) }
        let shippedSlugs = shipped.map(\.slug)
        var out = shipped.filter { found.contains($0.slug) }.map { (slug: $0.slug, name: $0.name) }
        for slug in found.filter({ !shippedSlugs.contains($0) }).sorted() {
            out.append((slug: slug, name: displayName(for: slug)))
        }
        return out
    }

    /// "project-manager" -> "Project Manager". Short all-consonant slugs that
    /// are obviously acronyms ("hr", "qa") are upper-cased instead.
    static func displayName(for slug: String) -> String {
        if let s = shipped.first(where: { $0.slug == slug }) { return s.name }
        return slug.split(separator: "-").map { word -> String in
            let w = String(word)
            if w.count <= 2 { return w.uppercased() }
            return w.prefix(1).uppercased() + w.dropFirst()
        }.joined(separator: " ")
    }

    static func isShipped(_ slug: String) -> Bool { shipped.contains { $0.slug == slug } }

    static func exists(_ slug: String) -> Bool {
        FileManager.default.fileExists(atPath: url(for: slug).path)
    }

    // MARK: - Writing

    /// Writes any shipped template that isn't on disk. Never overwrites: a
    /// template the user has edited is their content, and silently replacing
    /// somebody's HR template on an update would be a nasty surprise. "Reset to
    /// default" is the deliberate way back.
    static func seedIfMissing() {
        for t in shipped where !exists(t.slug) {
            try? t.body.write(to: url(for: t.slug), atomically: true, encoding: .utf8)
        }
        migrateLegacyStyleFile()
    }

    /// `summary_style.txt` was the single-file version of this. Anything the
    /// user actually wrote in it becomes a template called "My Style" and is
    /// selected, so the upgrade doesn't quietly drop their customization.
    private static func migrateLegacyStyleFile() {
        let legacy = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".nikxel/summary_style.txt")
        guard let raw = try? String(contentsOf: legacy, encoding: .utf8) else { return }
        let content = raw.components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // All comments means they never wrote anything -- just retire the file.
        if content.isEmpty {
            try? FileManager.default.removeItem(at: legacy)
            return
        }
        let slug = "my-style"
        if !exists(slug) {
            let header = """
            # My Style -- carried over from summary_style.txt, which this replaces.
            # Edit freely. Lines starting with # are ignored.

            """
            try? (header + content).write(to: url(for: slug), atomically: true, encoding: .utf8)
            NikxelSettings.summaryTemplate = slug
        }
        try? FileManager.default.removeItem(at: legacy)
    }

    /// Creates a template from a display name. Returns its slug, or nil if the
    /// name is unusable or already taken.
    @discardableResult
    static func create(named name: String, copying from: String? = nil) -> String? {
        let slug = slugify(name)
        guard !slug.isEmpty, !exists(slug) else { return nil }
        var body = """
        # \(name)
        # How you want your meeting summaries written, as plain instructions --
        # one per line, the way you'd tell a person. Lines starting with # are ignored.
        #
        # These override the built-in structure: you can drop a section you don't
        # use, add one you do, change the order, or set the length and tone.
        #
        # Two headings to leave spelled exactly as they are if you keep them:
        # "## Action Items" and "## Follow-Up Meetings" are read by name when
        # sending tasks to Google.

        """
        if let from = from {
            let copied = instructions(in: from)
            if !copied.isEmpty {
                body += "# Copied from \(displayName(for: from)):\n\n" + copied + "\n"
            }
        }
        try? body.write(to: url(for: slug), atomically: true, encoding: .utf8)
        return slug
    }

    /// Restores a shipped template to what the current build ships. Only
    /// meaningful for shipped slugs -- a user's own template has no default.
    @discardableResult
    static func reset(_ slug: String) -> Bool {
        guard let t = shipped.first(where: { $0.slug == slug }) else { return false }
        try? t.body.write(to: url(for: slug), atomically: true, encoding: .utf8)
        return true
    }

    static func delete(_ slug: String) {
        try? FileManager.default.removeItem(at: url(for: slug))
        if NikxelSettings.summaryTemplate == slug { NikxelSettings.summaryTemplate = "default" }
    }

    static func slugify(_ name: String) -> String {
        let lowered = name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        var out = ""
        for ch in lowered {
            if ch.isLetter || ch.isNumber { out.append(ch) }
            else if ch == " " || ch == "-" || ch == "_" { if !out.hasSuffix("-") { out.append("-") } }
        }
        while out.hasPrefix("-") { out.removeFirst() }
        while out.hasSuffix("-") { out.removeLast() }
        return String(out.prefix(40))
    }

    // MARK: - The shipped set

    struct Template {
        let slug: String
        let name: String
        let body: String
    }

    static let shipped: [Template] = [
        Template(slug: "default", name: "Default (balanced)", body: defaultBody),
        Template(slug: "developer", name: "Developer", body: developerBody),
        Template(slug: "project-manager", name: "Project Manager", body: projectManagerBody),
        Template(slug: "hr", name: "HR", body: hrBody),
        Template(slug: "co-founder", name: "Co-founder", body: coFounderBody),
    ]

    // Every body is plain instructions with a `#` header. The headers are
    // stripped before the text reaches the model, so they can say anything.

    private static let defaultBody = """
    # Default -- the built-in structure, unchanged.
    #
    # Every line below is a comment, so this template adds nothing to the prompt
    # and you get the standard summary: Summary, Speakers, Per-Speaker
    # Highlights, Decisions, Blockers & Risks, Open Questions, Action Items,
    # Follow-Up Meetings, Agent Prompts.
    #
    # To tweak it, delete the # from a line below or write your own. To start
    # from a role instead, pick one from the Summary Template menu.
    #
    #   Keep the summary to three sentences.
    #   Drop the Agent Prompts section, I don't use a coding agent.
    #   Write owners as first names only.
    """

    private static let developerBody = """
    # Developer -- for standups, design discussions, debugging sessions and
    # handoffs. Keeps the agent prompts and the exact technical wording.

    Keep the Agent Prompts section — it is the main reason this call was recorded.

    In Decisions, record the option that was chosen AND the options that were
    rejected, each with the reason given. "Chose Postgres over DynamoDB because
    the access pattern is relational" is the useful form; "chose Postgres" is not.

    Preserve technical wording exactly as it was spoken: endpoint paths, table
    and column names, flag names, env vars, version numbers, error messages and
    error codes. Do not tidy them into prose or guess at a spelling you did not
    hear clearly — write what you heard and flag it as uncertain.

    Add a "## Technical Context" section for the constraints and facts that
    aren't tasks: current numbers (latency, error rates, row counts, cost),
    version and compatibility limits, known broken behaviour, and anything
    stated about how the existing system works. This is the section that saves
    re-asking a week later.

    In Blockers & Risks, say what the dependency actually is, who owns it, and
    what specifically would unblock it.

    In Action Items, separate work that can start now from work that is waiting
    on a decision. Mark the second kind as blocked and name the decision it is
    waiting on.

    If the call reviewed code or a PR, add a "## Review Notes" section listing
    what was asked for, agreed, and explicitly waved through.
    """

    private static let projectManagerBody = """
    # Project Manager -- for status calls, planning and cross-team syncs.
    # Optimised for owners, dates, dependencies and what moved.

    Open with a "## Status at a Glance" section: three to five bullets covering
    what is on track, what slipped, and what needs attention this week.

    Every action item must carry an owner and a date. Where the meeting did not
    give one, write "Owner: Unassigned" or "Due: Not specified" and also list it
    under a "## Gaps" section at the end — an item nobody owns is the thing most
    likely to be missed, and it should be visible rather than blank.

    Add a "## Scope & Timeline Changes" section for anything that moved a date,
    added scope, or cut scope. Write each as before → after, with who agreed to
    it. If nothing moved, write "- None."

    Add a "## Dependencies" section: who is waiting on whom, across people and
    teams, and what each one is waiting for.

    Order Blockers & Risks by how many people or workstreams each one is
    holding up, worst first.

    Keep Per-Speaker Highlights brief — one or two lines per person covering
    what they own and what they reported.

    Keep the Agent Prompts section; it is what gets forwarded to the engineers.
    """

    private static let hrBody = """
    # HR -- for 1:1s, interviews, performance and policy conversations.
    # Careful with commitments and wording; no engineering sections.

    Drop the Agent Prompts section entirely.

    Rename "Per-Speaker Highlights" to "## Per-Person Notes".

    Add a "## Commitments Made" section near the top: anything promised to a
    person — compensation, title, leave, timelines, headcount, training,
    support, a review date. Quote the promise in the words it was made in, and
    name who made it. These are the lines that get revisited months later, so
    accuracy matters more here than anywhere else in the document.

    Add a "## Concerns Raised" section for what people said was bothering them,
    in their own words. Record what was actually said and how strongly it was
    put. Do not diagnose anyone, do not speculate about how they were feeling
    beyond what they stated, and do not infer anything about health, family,
    beliefs or any other personal characteristic that was not explicitly and
    voluntarily raised as relevant by the person themselves.

    Where something is contested, disputed, or likely to be revisited, quote the
    exact wording rather than paraphrasing it, and attribute it clearly.

    In Action Items, separate administrative follow-ups (paperwork, scheduling,
    approvals) from conversations that need to be had with a person, and give
    the second kind a named owner and a date.

    Keep the tone factual and neutral throughout. This note may end up being
    read by the person it is about.
    """

    private static let coFounderBody = """
    # Co-founder -- for investor calls, partner meetings, hiring debriefs and
    # leadership syncs. Short, decision-first, money-aware.

    Lead the Summary with the decision or the number that mattered, not with the
    chronology of the call. Three or four sentences, no more.

    Put a "## Needs a Decision From Me" section immediately after the Summary,
    before everything else. One bullet per thing waiting on you, each with the
    options as they were presented, what is at stake, and any deadline that was
    mentioned. If nothing is waiting on you, write "- None." and move on.

    Add a "## Money" section for every figure that came up — revenue, burn,
    runway, pricing, cost, salary, valuation, raise size. Record each with its
    units and the period it refers to, exactly as it was said. Never round, never
    convert, and never carry a number into this section that was not stated.

    In Decisions, record the reasoning and what was traded away to get there,
    not just the outcome.

    Add a "## Commitments to Outsiders" section for anything promised to a
    customer, investor, candidate, partner or vendor, with who promised it and
    by when.

    Drop Per-Speaker Highlights unless there was real disagreement on the call —
    if there was, keep it and make the disagreement explicit.

    Drop the Agent Prompts section.

    Keep the whole document tight. If it does not change a decision, a number or
    an owner, leave it out.
    """
}
