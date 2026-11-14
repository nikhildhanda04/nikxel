import AppKit
import CoreText

/// Writes a generated note out as PDF or Word alongside the Markdown the agent
/// produced, so the file can be shared with people who don't want a .md.
///
/// No new dependencies: Markdown becomes HTML here, AppKit turns that into an
/// attributed string, and macOS writes .docx from it directly. PDF is laid out
/// with CoreText.
enum NoteExporter {
    /// Markdown is always written -- it's what the agent produced and what the
    /// other formats are rendered from.
    enum Format: String, CaseIterable {
        case page, markdown, pdf, word

        var displayName: String {
            switch self {
            case .page: return "Page (.html)"
            case .markdown: return "Markdown (.md)"
            case .pdf: return "PDF (.pdf)"
            case .word: return "Word (.docx)"
            }
        }

        var fileExtension: String {
            switch self {
            case .page: return "html"
            case .markdown: return "md"
            case .pdf: return "pdf"
            case .word: return "docx"
            }
        }
    }

    enum ExportError: Error, LocalizedError {
        case renderFailed

        var errorDescription: String? { "Couldn't render the note into that format." }
    }

    /// Converts `markdown` and writes it next to `markdownURL` with the right
    /// extension. Returns the new file, or the original for `.markdown`.
    static func export(markdown: String, from markdownURL: URL, as format: Format) throws -> URL {
        guard format != .markdown else { return markdownURL }

        let destination = markdownURL.deletingPathExtension()
            .appendingPathExtension(format.fileExtension)
        if format == .page {
            try NotePage.html(from: markdown).write(to: destination, atomically: true, encoding: .utf8)
            return destination
        }
        let attributed = try attributedString(from: markdown)

        switch format {
        case .markdown, .page:
            return markdownURL
        case .word:
            let data = try attributed.data(
                from: NSRange(location: 0, length: attributed.length),
                documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML]
            )
            try data.write(to: destination)
        case .pdf:
            try writePDF(attributed, to: destination)
        }
        return destination
    }

    // MARK: - Rendering

    private static func attributedString(from markdown: String) throws -> NSAttributedString {
        let html = Self.html(from: markdown)
        guard let data = html.data(using: .utf8) else { throw ExportError.renderFailed }

        // NSAttributedString's HTML importer must run on the main thread --
        // generation happens on a background queue, so hop over for this step.
        var result: NSAttributedString?
        if Thread.isMainThread {
            result = NSAttributedString(html: data, options: [.documentType: NSAttributedString.DocumentType.html], documentAttributes: nil)
        } else {
            DispatchQueue.main.sync {
                result = NSAttributedString(html: data, options: [.documentType: NSAttributedString.DocumentType.html], documentAttributes: nil)
            }
        }
        guard let attributed = result else { throw ExportError.renderFailed }
        return attributed
    }

    private static func writePDF(_ attributed: NSAttributedString, to url: URL) throws {
        // US Letter at 72dpi with a 0.75" margin.
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        let textRect = mediaBox.insetBy(dx: 54, dy: 54)

        guard let consumer = CGDataConsumer(url: url as CFURL),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw ExportError.renderFailed
        }

        let framesetter = CTFramesetterCreateWithAttributedString(attributed as CFAttributedString)
        var start = 0
        while start < attributed.length {
            context.beginPDFPage(nil)
            let path = CGPath(rect: textRect, transform: nil)
            // length 0 means "as much as fits", which is what paginates this.
            let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: start, length: 0), path, nil)
            CTFrameDraw(frame, context)
            let drawn = CTFrameGetVisibleStringRange(frame)
            context.endPDFPage()
            // Nothing fit (a single run taller than the page) -- stop rather
            // than spin out an unbounded PDF.
            if drawn.length == 0 { break }
            start += drawn.length
        }
        context.closePDF()
    }

    // MARK: - Markdown

    /// Markdown-to-HTML for what the note prompts actually emit: headings,
    /// lists, task lines, bold/italic/code, rules and paragraphs. Not a general
    /// Markdown implementation.
    ///
    /// Styled to read as a document rather than a text dump: the title becomes
    /// an eyebrow + date, the first Summary line a lead, "— Owner: X" style
    /// fields chips, and "None." sections fade out. The same HTML feeds the
    /// browser page and the PDF/Word export; AppKit's importer ignores what it
    /// can't do (radius, padding on spans), so both stay readable.
    static func html(from markdown: String) -> String {
        var out = ""
        var listKind: String?          // "ul", "ol" or "tasks" while a list is open
        var inCodeBlock = false
        var inSection = false
        var section = ""
        var leadDone = false
        var title = "Nikxel"

        func closeList() {
            if let kind = listKind { out += kind == "ol" ? "</ol>\n" : "</ul>\n"; listKind = nil }
        }
        func openList(_ kind: String) {
            guard listKind != kind else { return }
            closeList()
            out += kind == "ol" ? "<ol>\n" : kind == "tasks" ? "<ul class=\"tasks\">\n" : "<ul>\n"
            listKind = kind
        }

        for rawLine in markdown.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)

            if line.hasPrefix("```") {
                closeList()
                out += inCodeBlock ? "</pre>\n" : "<pre>"
                inCodeBlock.toggle()
                continue
            }
            if inCodeBlock {
                out += escape(rawLine) + "\n"
                continue
            }

            if line.isEmpty { closeList(); continue }

            if line.hasPrefix("#") {
                closeList()
                let level = min(line.prefix(while: { $0 == "#" }).count, 6)
                let text = line.dropFirst(level).trimmingCharacters(in: .whitespaces)
                if level == 1 {
                    title = text
                    out += header(text)
                } else if level == 2 {
                    if inSection { out += "</section>\n" }
                    inSection = true
                    section = text.lowercased()
                    out += "<section>\n<h2>\(inline(text))</h2>\n"
                } else {
                    out += "<h\(level)>\(inline(text))</h\(level)>\n"
                }
            } else if line == "---" || line == "***" || line == "___" {
                closeList()
                out += "<hr/>\n"
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                var item = String(line.dropFirst(2))
                var done: Bool?
                if item.hasPrefix("[ ] ") { done = false } else if item.lowercased().hasPrefix("[x] ") { done = true }
                if done != nil { item = String(item.dropFirst(4)) }
                if isNone(item) { closeList(); out += "<p class=\"none\">\(inline(item))</p>\n"; continue }
                if let done = done {
                    openList("tasks")
                    out += "<li class=\"task\"><span class=\"box\">\(done ? "☑" : "☐")</span>&nbsp; \(fields(item))</li>\n"
                } else {
                    openList("ul")
                    out += "<li>\(fields(item))</li>\n"
                }
            } else if let match = numberedItem(line) {
                openList("ol")
                out += "<li>\(inline(match))</li>\n"
            } else if isNone(line) {
                closeList()
                out += "<p class=\"none\">\(inline(line))</p>\n"
            } else {
                closeList()
                // The opening line of Summary is the one most people stop at.
                // Older prompts wrote Summary as one long paragraph; that's not a lead.
                let lead = section == "summary" && !leadDone && line.count <= 240
                if section == "summary" { leadDone = true }
                // "**Name:** what they said" / "**Name**" -- a speaker heading.
                let speaker = line.hasPrefix("**") && (line.hasSuffix("**") || line.contains(":**"))
                let cls = lead ? " class=\"lead\"" : speaker ? " class=\"who\"" : ""
                out += "<p\(cls)>\(inline(line))</p>\n"
            }
        }
        closeList()
        if inCodeBlock { out += "</pre>\n" }
        if inSection { out += "</section>\n" }

        return """
        <!doctype html>
        <html><head><meta charset="utf-8">\(favicon)<meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(escape(title))</title><style>\(css)</style></head><body><main>
        \(out)</main></body></html>
        """
    }

    /// Website palette: paper, ink, the green accent, and the pastel chips.
    private static let css = """
    body { margin: 0; background: #f6faf5; color: #25302a; font-family: -apple-system, "Helvetica Neue", Helvetica, Arial, sans-serif; font-size: 11pt; line-height: 1.55; }
    main { max-width: 760px; margin: 32px auto; padding: 40px 48px; background: #ffffff; border: 1px solid #d7e9d6; border-radius: 18px; }
    .eyebrow { color: #23864d; font-size: 8.5pt; font-weight: 700; letter-spacing: 1.5pt; text-transform: uppercase; margin: 0 0 4pt 0; }
    h1 { font-size: 22pt; line-height: 1.2; font-weight: 700; margin: 0 0 6pt 0; }
    .meta { color: #5c6a60; font-size: 10pt; margin: 0 0 8pt 0; }
    section { margin-top: 22pt; }
    h2 { color: #23864d; font-size: 9pt; font-weight: 700; letter-spacing: 1.2pt; text-transform: uppercase; border-top: 1px solid #d7e9d6; padding-top: 12pt; margin: 22pt 0 8pt 0; }
    h3 { font-size: 12pt; margin: 14pt 0 6pt 0; }
    p { margin: 0 0 8pt 0; }
    .lead { font-size: 13pt; line-height: 1.5; font-weight: 600; }
    .who { margin-top: 12pt; }
    .who b { color: #23864d; }
    ul, ol { margin: 0 0 8pt 0; padding-left: 18pt; }
    li { margin: 0 0 5pt 0; }
    ul.tasks { list-style-type: none; padding-left: 0; }
    .task { margin: 0 0 9pt 0; padding: 8pt 12pt; background: #f6faf5; border-radius: 10px; }
    .box { color: #23864d; font-size: 12pt; }
    .chip { font-size: 8.5pt; font-weight: 600; background: #d6f3e3; border-radius: 99px; padding: 1pt 7pt; white-space: nowrap; }
    .chip .k { color: #5c6a60; font-weight: 500; }
    .chip.due, .chip.when { background: #fff3c4; }
    .chip.duration { background: #e8ddff; }
    .chip.with { background: #ffe6d3; }
    .chip.unset { background: #eef2ee; color: #5c6a60; }
    .none { color: #8a968d; font-style: italic; }
    code { font-family: Menlo, monospace; font-size: 9.5pt; background: #f6faf5; border-radius: 4px; padding: 0 3pt; }
    pre { font-family: Menlo, monospace; font-size: 9pt; line-height: 1.5; background: #f6faf5; border: 1px solid #d7e9d6; border-radius: 10px; padding: 10pt 12pt; white-space: pre-wrap; }
    hr { border: 0; border-top: 1px solid #d7e9d6; }
    @media print { body { background: #fff; } main { border: 0; margin: 0; padding: 0; } }
    """

    /// "Meeting — 2026-11-12 13:21" -> an eyebrow ("Minutes of meeting") over
    /// a readable date. Anything else is shown as-is.
    private static func header(_ title: String) -> String {
        let parts = title.components(separatedBy: " — ")
        guard parts.count == 2 else { return "<h1>\(inline(title))</h1>\n" }
        let kind = parts[0] == "Meeting" ? "Minutes of meeting" : parts[0]
        let parse = DateFormatter()
        parse.locale = Locale(identifier: "en_US_POSIX")
        parse.dateFormat = "yyyy-MM-dd HH:mm"
        guard let date = parse.date(from: parts[1]) else {
            return "<p class=\"eyebrow\">\(escape(kind))</p>\n<h1>\(inline(parts[1]))</h1>\n"
        }
        let day = DateFormatter(); day.dateFormat = "EEEE, d MMMM yyyy"
        let time = DateFormatter(); time.timeStyle = .short
        return "<p class=\"eyebrow\">\(escape(kind))</p>\n<h1>\(day.string(from: date))</h1>\n<p class=\"meta\">\(time.string(from: date))</p>\n"
    }

    /// "- None." / "None — no tasks came out of this meeting."
    static func isNone(_ text: String) -> Bool {
        let t = text.lowercased().trimmingCharacters(in: .whitespaces)
        return t == "none" || t == "none." || t.hasPrefix("none —") || t.hasPrefix("none -")
    }

    /// "**Task** — Owner: Vikas — Due: Not specified" -> ("**Task**", [("Owner",
    /// "Vikas"), ("Due", "Not specified")]). Parts that aren't fields stay text.
    static func splitFields(_ item: String) -> (text: String, fields: [(key: String, value: String)]) {
        var text: [String] = [], out: [(key: String, value: String)] = []
        for (i, part) in item.components(separatedBy: " — ").enumerated() {
            guard i > 0, let colon = part.firstIndex(of: ":") else { text.append(part); continue }
            let key = part[..<colon].trimmingCharacters(in: .whitespaces)
            let value = part[part.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, key.count <= 12, !value.isEmpty,
                  key.allSatisfy({ $0.isLetter || $0 == " " }) else { text.append(part); continue }
            out.append((key, value))
        }
        return (text.joined(separator: " — "), out)
    }

    /// A field as a chip; "Unassigned" / "Not specified" greyed out.
    static func chip(_ key: String, _ value: String) -> String {
        let unset = ["not specified", "unassigned"].contains(value.lowercased())
        let cls = "chip \(key.lowercased().replacingOccurrences(of: " ", with: "-"))\(unset ? " unset" : "")"
        return "<span class=\"\(cls)\">&nbsp;<span class=\"k\">\(escape(key))</span>&nbsp; \(inline(value))&nbsp;</span>"
    }

    private static func fields(_ item: String) -> String {
        let (text, fields) = splitFields(item)
        let body = inline(text)
        return fields.isEmpty ? body : "\(body)<br/>\(fields.map { chip($0.key, $0.value) }.joined(separator: " "))"
    }

    /// "1. text" / "2) text" -> "text"
    private static func numberedItem(_ line: String) -> String? {
        let digits = line.prefix(while: { $0.isNumber })
        guard !digits.isEmpty else { return nil }
        let rest = line.dropFirst(digits.count)
        guard rest.hasPrefix(". ") || rest.hasPrefix(") ") else { return nil }
        return String(rest.dropFirst(2))
    }

    /// The app icon (64px), inlined so every page Nikxel writes shows it in
    /// the tab -- also after it's shared or opened on another machine.
    static let favicon = #"<link rel="icon" type="image/png" href="data:image/png;base64,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">"#

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    /// Escapes first, then applies inline markers, so the tags it emits survive.
    static func inline(_ text: String) -> String {
        var s = escape(text)
        s = wrap(s, marker: "**", tag: "b")
        s = wrap(s, marker: "`", tag: "code")
        // Any "**" still standing was unmatched. Hide it from the italic pass,
        // which would otherwise read it as an empty <i></i> and delete it.
        s = s.replacingOccurrences(of: "**", with: boldSentinel)
        s = wrap(s, marker: "*", tag: "i")
        s = s.replacingOccurrences(of: boldSentinel, with: "**")
        return s
    }

    private static let boldSentinel = "\u{E000}"   // private-use area

    /// Pairs up `marker`-delimited runs. Unmatched trailing markers are left
    /// as-is rather than swallowing the rest of the line.
    private static func wrap(_ text: String, marker: String, tag: String) -> String {
        let parts = text.components(separatedBy: marker)
        guard parts.count >= 3 else { return text }
        var out = parts[0]
        var i = 1
        while i < parts.count {
            if i + 1 < parts.count || parts.count % 2 == 1 {
                out += "<\(tag)>\(parts[i])</\(tag)>"
                i += 1
                if i < parts.count { out += parts[i]; i += 1 }
            } else {
                out += marker + parts[i]
                i += 1
            }
        }
        return out
    }
}
