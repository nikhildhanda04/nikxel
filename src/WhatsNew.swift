import Foundation

/// What each update added, from WHATSNEW.md (bundled by build.sh as
/// whatsnew.md): the Nikxel window's What's new section, and the tour that
/// runs once after an update. Mirrors windows/src/main/system/whatsNew.ts.
enum WhatsNew {
    /// One stop on an update's tour: a section to open, and what to say there.
    struct Step: Equatable { var section: String; var title: String; var text: String }
    struct Item: Equatable { var title: String; var body: String; var tour: [Step] }
    struct Release: Equatable { var id: String; var items: [Item] }

    /// `## id` starts an update, `### title` a change, and each `tour: section | title | text`
    /// line under a change is a step of its tour (title and text default to the change's);
    /// the other lines are its paragraph. Text before the first update and HTML comments are skipped.
    static func parse(_ md: String) -> [Release] {
        var out: [Release] = [], comment = false
        var raw: [[(title: String, lines: [String], tour: [[String]])]] = []
        for l in md.components(separatedBy: .newlines) {
            let line = l.trimmingCharacters(in: .whitespaces)
            if comment { if line.contains("-->") { comment = false }; continue }
            if line.hasPrefix("<!--") { comment = !line.contains("-->"); continue }
            if line.hasPrefix("## ") {
                out.append(Release(id: String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces), items: [])); raw.append([])
            } else if line.hasPrefix("### "), !raw.isEmpty {
                raw[raw.count - 1].append((String(line.dropFirst(4)).trimmingCharacters(in: .whitespaces), [], []))
            } else if let r = raw.indices.last, let i = raw[r].indices.last {
                if line.lowercased().hasPrefix("tour:") {
                    raw[r][i].tour.append(line.dropFirst(5).split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false)
                        .map { $0.trimmingCharacters(in: .whitespaces) })
                } else {
                    raw[r][i].lines.append(line)
                }
            }
        }
        for r in out.indices {
            out[r].items = raw[r].map { it in
                // Lines become paragraphs at blank lines.
                let body = it.lines.split(separator: "", omittingEmptySubsequences: true).map { $0.joined(separator: " ") }.joined(separator: "\n\n")
                let steps = it.tour.compactMap { p -> Step? in
                    guard let section = p.first, !section.isEmpty else { return nil }
                    let title = p.count > 1 && !p[1].isEmpty ? p[1] : it.title
                    let text = p.count > 2 && !p[2].isEmpty ? p[2] : body
                    return Step(section: section, title: title, text: text)
                }
                return Item(title: it.title, body: body, tour: steps)
            }
        }
        return out
    }

    /// The updates someone hasn't seen yet, newest first: those above `seen`.
    /// Never seen anything: only the newest, not the whole history.
    static func unseen(_ releases: [Release], seen: String?) -> [String] {
        guard let first = releases.first else { return [] }
        guard let seen, !seen.isEmpty else { return [first.id] }
        return Array(releases.prefix { $0.id != seen }.map(\.id))
    }

    static var releases: [Release] {
        let bundled = Bundle.main.url(forResource: "whatsnew", withExtension: "md")
        return bundled.flatMap { try? String(contentsOf: $0, encoding: .utf8) }.map(parse) ?? []
    }

    static func dicts(_ releases: [Release]) -> [[String: Any]] {
        releases.prefix(12).map { r in
            ["id": r.id, "items": r.items.map { ["title": $0.title, "body": $0.body,
                                    "tour": $0.tour.map { ["section": $0.section, "title": $0.title, "text": $0.text] }] }]
        }
    }
}
