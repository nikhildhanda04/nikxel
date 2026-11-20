import Foundation

/// The LLM merge pass that keeps TwinProfile.learned current. Mirrors twinDistiller.ts.
enum TwinDistiller {
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
        - The whole profile, corrections block included, must stay under 3000 characters.

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

    /// `old` when `new` is blank; else `new` cut to `cap` characters on a line boundary.
    static func accept(new: String, old: String, cap: Int = 3000) -> String {
        let t = new.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return old }
        if t.count <= cap { return t }
        let head = String(t.prefix(cap))
        if t[t.index(t.startIndex, offsetBy: cap)] == "\n" { return head }
        guard let nl = head.lastIndex(of: "\n") else { return head }
        return String(head[..<nl])
    }

    static func distill(meetingSelfLines: [String], sentMessages: [String], daySummary: String,
                        runPrompt: (_ prompt: String, _ kind: String) throws -> String) {
        guard !(meetingSelfLines.isEmpty && sentMessages.isEmpty && daySummary.isEmpty) else { return }
        let old = TwinProfile.learned
        do {
            let out = try runPrompt(mergePrompt(current: old, meetingSelfLines: meetingSelfLines,
                                                sentMessages: sentMessages, daySummary: daySummary), "twin-distill")
            TwinProfile.learned = accept(new: out, old: old)
        } catch { cblog("twin distill failed: \(error)") }
    }
}
