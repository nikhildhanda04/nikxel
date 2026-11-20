import Foundation

/// Work-and-business facts Nikxel has read from the user's ERP, kept sealed in
/// ~/.nikxel/twin/erp.md (0600, like the twin profile). Its own file — the
/// voice distiller rewrites profile.md wholesale through the LLM and can't be
/// trusted to preserve a foreign region, so ERP facts live apart and inject
/// alongside, after the user's own context (so the user always wins).
/// Mirrors erpContext.ts.
enum ErpContext {
    private static var file: String { NSHomeDirectory() + "/.nikxel/twin/erp.md" }

    static var facts: String {
        get { (try? String(contentsOfFile: file, encoding: .utf8)) ?? "" }
        set {
            if !newValue.isEmpty {
                try? FileManager.default.createDirectory(atPath: (file as NSString).deletingLastPathComponent,
                                                         withIntermediateDirectories: true)
                try? newValue.write(toFile: file, atomically: true, encoding: .utf8)
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file)
            } else {
                try? FileManager.default.removeItem(atPath: file)
            }
        }
    }

    /// The ERP facts as a prompt block, or "" when empty.
    static var injectedBlock: String {
        let t = facts.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return "" }
        return "What Nikxel has learned about this user's work and business from their ERP — the projects, tasks, people, and customers they work with.\n\(t)"
    }

    /// Prompt that turns captured ERP page text into terse work-context facts.
    static func readerPrompt(capturedText: String) -> String {
        """
        Below is text captured from the pages of the user's ERP, read as the signed-in user (so it is only what they are allowed to see). Extract this user's work context as short facts an assistant can carry everywhere: the projects and tasks they work on, the people they work with, and the business and customers involved. Return the facts only — no commentary, no preamble, no code fences. Be terse; prefer facts over prose. Keep the whole thing under 2000 characters. If there is nothing useful, return nothing.

        ERP PAGES:
        \(capturedText)
        """
    }

    /// `old` when `new` is blank or has no real content (a refusal); else `new`
    /// trimmed and cut to `cap` on a line boundary.
    static func accept(new: String, old: String, cap: Int = 2000) -> String {
        let t = new.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty || t.rangeOfCharacter(from: .alphanumerics) == nil { return old }
        if t.count <= cap { return t }
        let head = String(t.prefix(cap))
        if t[t.index(t.startIndex, offsetBy: cap)] == "\n" { return head }
        guard let nl = head.lastIndex(of: "\n") else { return head }
        return String(head[..<nl])
    }

    /// Capture → read → store, with the capture and the LLM call injected (so
    /// it runs without a browser in tests). Empty capture keeps the old facts;
    /// a blank/refusal read keeps them too (via `accept`). The browser-backed
    /// capture and the connection guard live in ErpCrawl.ingest.
    static func ingestWith(capture: () -> [String], runPrompt: (_ prompt: String, _ kind: String) throws -> String) {
        let sections = capture()
        guard !sections.isEmpty else { return }
        let out = (try? runPrompt(readerPrompt(capturedText: boundText(sections: sections)), "erp-ingest")) ?? ""
        facts = accept(new: out, old: facts)
    }

    /// Captured sections joined and truncated to `cap` chars (on a line
    /// boundary) — the bound on what the reader LLM ever sees in one run.
    static func boundText(sections: [String], cap: Int = 8000) -> String {
        let joined = sections.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n---\n\n")
        if joined.count <= cap { return joined }
        let head = String(joined.prefix(cap))
        guard let nl = head.lastIndex(of: "\n") else { return head }
        return String(head[..<nl])
    }
}
