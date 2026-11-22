import Foundation

/// The LLM merge pass that keeps TwinProfile.learned current. Mirrors twinDistiller.ts.
enum TwinDistiller {
    private static let lock = NSLock()  // serializes read-modify-write of the profile

    static func mergePrompt(current: String, meetingSelfLines: [String], sentMessages: [String], daySummary: String) -> String {
        func list(_ a: [String]) -> String { a.isEmpty ? "(none)" : a.map { "- \($0)" }.joined(separator: "\n") }
        return """
        You maintain a short profile of the user so an assistant can write and speak like them. Merge the NEW SIGNALS into the CURRENT PROFILE and return the FULL updated profile, nothing else (no commentary, no code fences).

        Sections, in order: Who / Work & projects / Names & terms / Voice & style / Relationships.
        - Keep what is still true, add what is new, drop what is stale. Be terse; prefer facts over prose.
        - Voice & style: a short description of how they talk and write, plus a few verbatim example lines taken from their own words below.
        - Keep the corrections block, refreshed. It must stay exactly in this form, one `wrong -> right` per line:
        <!--corrections-->
        wrong -> right
        <!--/corrections-->
          Only add a correction when a term is clearly mis-heard or mis-spelled and the right form is certain. Corrections are applied one after another, so do NOT chain them (no `right` that is itself another entry's `wrong`). Matching is on whole words, so prefer ordinary word terms; avoid symbols like C++ or .NET.
        - The whole profile, corrections block included, must stay under 3000 characters. Rough budget: Who 300, Work & projects 1000 (one line per active project — where it stands, not its history), Names & terms 400, Voice & style 600, Relationships 400, corrections the rest. Every section must be present.

        CURRENT PROFILE:
        \(current.isEmpty ? "(empty)" : current)

        NEW SIGNALS

        Lines the user said in meetings:
        \(list(meetingSelfLines))

        Messages the user sent on WhatsApp:
        \(list(sentMessages))

        Summary of the user's day:
        \(daySummary.isEmpty ? "(none)" : daySummary)
        """
    }

    private static let header = "^[#*\\s]*(Who|Work & projects|Names & terms|Voice & style|Relationships)[*\\s:]*$"

    /// `old` when `new` is blank or not profile-shaped; else `new` brought under `cap` characters.
    /// Over the cap, the longest section loses its last lines first, so a long project list can't
    /// push Voice & style, Relationships and the corrections off the end.
    static func accept(new: String, old: String, cap: Int = 3000) -> String {
        var t = new.trimmingCharacters(in: .whitespacesAndNewlines)
        // Malformed (refusal, prose, garbage): must have a section header line or the corrections marker.
        if t.range(of: "(?m)" + header, options: .regularExpression) == nil && !t.contains("<!--corrections-->") { return old }
        if t.count <= cap { return t }
        t = trimLongestSection(t, cap: cap)
        if t.count <= cap { return t }
        let head = String(t.prefix(cap))
        if t[t.index(t.startIndex, offsetBy: cap)] == "\n" { return head }
        guard let nl = head.lastIndex(of: "\n") else { return head }
        return String(head[..<nl])
    }

    private static func trimLongestSection(_ t: String, cap: Int) -> String {
        var lines = t.components(separatedBy: "\n")
        // Each line's section (-1 before the first header); nil = never dropped (headers, the corrections block).
        var section: [Int?] = [], s = -1, inCorrections = false
        for l in lines {
            if l.contains("<!--corrections-->") { inCorrections = true }
            if l.range(of: header, options: .regularExpression) != nil { s += 1; section.append(nil) }
            else { section.append(inCorrections ? nil : s) }
            if l.contains("<!--/corrections-->") { inCorrections = false }
        }
        var total = t.count
        while total > cap {
            var size: [Int: Int] = [:]
            for (i, sec) in section.enumerated() { if let sec { size[sec, default: 0] += lines[i].count + 1 } }
            guard let longest = size.max(by: { $0.value < $1.value })?.key,
                  let i = section.lastIndex(where: { $0 == longest }) else { break }
            total -= lines[i].count + 1
            lines.remove(at: i); section.remove(at: i)
        }
        return lines.joined(separator: "\n")
    }

    static func distill(meetingSelfLines: [String], sentMessages: [String], daySummary: String,
                        runPrompt: (_ prompt: String, _ kind: String) throws -> String) {
        guard !(meetingSelfLines.isEmpty && sentMessages.isEmpty && daySummary.isEmpty) else { return }
        lock.lock(); defer { lock.unlock() }
        let old = TwinProfile.learned
        do {
            let out = try runPrompt(mergePrompt(current: old, meetingSelfLines: meetingSelfLines,
                                                sentMessages: sentMessages, daySummary: daySummary), "twin-distill")
            TwinProfile.learned = accept(new: out, old: old)
        } catch { cblog("twin distill failed: \(error)") }
    }
}
