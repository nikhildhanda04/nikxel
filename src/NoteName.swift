import Foundation

/// A meeting or notes summary is saved as "2026-11-24-153012.md" (+ .html,
/// .transcript.txt, …). Its page offers a title Nikxel suggests; saving one
/// renames every file of that summary to "Q3 Budget Review 2026-11-24-153012.*".
/// Anything that dates a summary by its file name reads `stamp`, which finds the
/// timestamp at the end. Same logic in windows/src/main/system/noteName.ts.
enum NoteName {
    struct Failure: LocalizedError { let errorDescription: String? }

    /// Still named by its timestamp alone.
    static func isUnnamed(_ stem: String) -> Bool {
        stem.range(of: #"^\d{4}-\d{2}-\d{2}-\d{6}$"#, options: .regularExpression) != nil
    }

    /// The "yyyy-MM-dd-HHmmss" a summary is dated by: the whole stem, or its
    /// end once named ("<name> <stamp>"). Older "yyyy-MM-dd-HHmm" stems too.
    static func stamp(_ stem: String) -> String {
        stem.range(of: #"\d{4}-\d{2}-\d{2}-\d{4}(\d{2})?$"#, options: .regularExpression).map { String(stem[$0]) } ?? stem
    }

    /// The agent's or the user's answer made safe as a file name: first line,
    /// no path or quote characters, at most 60 characters.
    static func clean(_ raw: String) -> String {
        let line = raw.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let bad = CharacterSet(charactersIn: "/\\:*?\"<>|`#").union(.controlCharacters)
        let kept = String(String.UnicodeScalarView(line.unicodeScalars.filter { !bad.contains($0) }))
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: " .'-"))
        return String(kept.prefix(60)).trimmingCharacters(in: .whitespaces)
    }

    static func prompt(summary: String) -> String {
        """
        Suggest a file name for this summary: 3 to 6 words, Title Case, naming what it was \
        about (the client, project or main decision). No date, no quotes, no file extension. \
        Reply with the name only.

        \(summary.prefix(6000))
        """
    }

    /// Renames every "<stem>.*" beside `page`, and its edit history in
    /// `editsDir`, to "<name> <stem>.*". Returns the renamed page.
    static func rename(_ page: URL, to raw: String, editsDir: URL) throws -> URL {
        let name = clean(raw), dir = page.deletingLastPathComponent()
        let stem = page.deletingPathExtension().lastPathComponent, newStem = "\(name) \(stem)"
        guard isUnnamed(stem) else { throw Failure(errorDescription: "This summary already has a name.") }
        guard name.contains(where: { $0.isLetter || $0.isNumber }) else {
            throw Failure(errorDescription: "Give it a name with at least one letter or number.")
        }
        let fm = FileManager.default
        let files = try fm.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix(stem + ".") }
        let moves = files.map { (dir.appendingPathComponent($0), dir.appendingPathComponent(newStem + $0.dropFirst(stem.count))) }
        guard !moves.contains(where: { fm.fileExists(atPath: $0.1.path) }) else {
            throw Failure(errorDescription: "A summary with that name already exists.")
        }
        for (from, to) in moves { try fm.moveItem(at: from, to: to) }
        try? fm.moveItem(at: editsDir.appendingPathComponent(stem), to: editsDir.appendingPathComponent(newStem))
        return dir.appendingPathComponent("\(newStem).\(page.pathExtension)")
    }
}
