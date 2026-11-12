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
            try html(from: markdown).write(to: destination, atomically: true, encoding: .utf8)
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
        <html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
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
    private static func isNone(_ text: String) -> Bool {
        let t = text.lowercased().trimmingCharacters(in: .whitespaces)
        return t == "none" || t == "none." || t.hasPrefix("none —") || t.hasPrefix("none -")
    }

    /// "**Task** — Owner: Vikas — Due: Not specified" -> the task, then a chip
    /// per "Key: value" field. Parts that aren't fields stay in the text.
    private static func fields(_ item: String) -> String {
        let parts = item.components(separatedBy: " — ")
        var text: [String] = [], chips: [String] = []
        for (i, part) in parts.enumerated() {
            guard i > 0, let colon = part.firstIndex(of: ":") else { text.append(part); continue }
            let key = part[..<colon].trimmingCharacters(in: .whitespaces)
            let value = part[part.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, key.count <= 12, !value.isEmpty,
                  key.allSatisfy({ $0.isLetter || $0 == " " }) else { text.append(part); continue }
            let unset = ["not specified", "unassigned"].contains(value.lowercased())
            let cls = "chip \(key.lowercased().replacingOccurrences(of: " ", with: "-"))\(unset ? " unset" : "")"
            chips.append("<span class=\"\(cls)\">&nbsp;<span class=\"k\">\(escape(key))</span>&nbsp; \(inline(value))&nbsp;</span>")
        }
        let body = inline(text.joined(separator: " — "))
        return chips.isEmpty ? body : "\(body)<br/>\(chips.joined(separator: " "))"
    }

    /// "1. text" / "2) text" -> "text"
    private static func numberedItem(_ line: String) -> String? {
        let digits = line.prefix(while: { $0.isNumber })
        guard !digits.isEmpty else { return nil }
        let rest = line.dropFirst(digits.count)
        guard rest.hasPrefix(". ") || rest.hasPrefix(") ") else { return nil }
        return String(rest.dropFirst(2))
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    /// Escapes first, then applies inline markers, so the tags it emits survive.
    private static func inline(_ text: String) -> String {
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
