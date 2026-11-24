import Foundation

/// Every summary under ~/Documents/nikxel, for the dashboard's Library: one
/// entry per stem (a meeting's .md, .html, .transcript.txt… are one entry),
/// newest first. Reads directory listings and the first lines of each .md only,
/// so it's cheap enough to run every time the window comes forward.
enum SummaryLibrary {
    static let root = URL(fileURLWithPath: NSHomeDirectory() + "/Documents/nikxel")
    static let kinds = ["meetings", "notes", "daily", "weekly"]

    struct Entry {
        let kind: String, title: String, date: String, snippet: String, file: URL
        var dict: [String: Any] {
            ["id": file.path, "kind": kind, "title": title, "date": date, "snippet": snippet, "ext": file.pathExtension]
        }
    }

    /// The file each summary opens as, in order of preference.
    private static let opens = ["html", "pdf", "docx", "md"]

    static func scan(_ root: URL = root) -> [Entry] {
        kinds.flatMap { scan(kind: $0, in: root.appendingPathComponent($0)) }.sorted { $0.date > $1.date }
    }

    static func scan(kind: String, in dir: URL) -> [Entry] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return [] }
        var byStem: [String: Set<String>] = [:]
        for name in names where !name.hasPrefix(".") {
            let url = URL(fileURLWithPath: name), stem = url.deletingPathExtension().lastPathComponent
            // "x.client.html", "x.transcript.txt", "x.sent.json" belong to x and don't open on their own.
            guard opens.contains(url.pathExtension), !stem.contains(".") else { continue }
            byStem[stem, default: []].insert(url.pathExtension)
        }
        return byStem.compactMap { stem, exts -> Entry? in
            guard let ext = opens.first(where: exts.contains) else { return nil }
            let file = dir.appendingPathComponent("\(stem).\(ext)")
            let md = exts.contains("md") ? head(dir.appendingPathComponent("\(stem).md")) : ""
            let (heading, snippet) = parse(md)
            let named = NoteName.stamp(stem) != stem ? String(stem.dropLast(NoteName.stamp(stem).count)).trimmingCharacters(in: .whitespaces) : ""
            let title = !named.isEmpty ? named
                : !heading.isEmpty ? heading
                : ext == "html" ? htmlTitle(file) ?? stem : stem
            return Entry(kind: kind, title: title, date: date(stem: stem, file: file), snippet: snippet, file: file)
        }
    }

    /// The first `# ` heading and the first line of prose under it.
    static func parse(_ md: String) -> (heading: String, snippet: String) {
        var heading = "", snippet = ""
        for raw in md.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if heading.isEmpty, line.hasPrefix("# ") { heading = String(line.dropFirst(2)); continue }
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix("|") || line.hasPrefix("---") || line.hasPrefix("<") { continue }
            snippet = line.replacingOccurrences(of: #"^[-*]\s+|\*\*|__"#, with: "", options: .regularExpression)
            break
        }
        return (heading, String(snippet.prefix(160)))
    }

    /// "yyyy-MM-dd HH:mm" from the stem's timestamp ("…2026-11-24-170838" or a
    /// day page's "2026-11-24"), else the file's modified time. Sorts as text.
    static func date(stem: String, file: URL) -> String {
        let stamp = NoteName.stamp(stem)
        if stamp.range(of: #"^\d{4}-\d{2}-\d{2}-\d{4}"#, options: .regularExpression) != nil {
            let c = Array(stamp)
            return "\(String(c[0..<10])) \(String(c[11..<13])):\(String(c[13..<15]))"
        }
        if stem.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil { return stem + " 00:00" }
        let mod = (try? FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date) ?? Date(timeIntervalSince1970: 0)
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: mod)
    }

    private static func head(_ url: URL) -> String {
        guard let h = FileHandle(forReadingAtPath: url.path) else { return "" }
        defer { try? h.close() }
        return String(decoding: h.readData(ofLength: 4096), as: UTF8.self)
    }

    private static func htmlTitle(_ url: URL) -> String? {
        let h = head(url)
        guard let r = h.range(of: #"(?<=<title>)[^<]+"#, options: .regularExpression) else { return nil }
        return String(h[r]).trimmingCharacters(in: .whitespaces)
    }
}
