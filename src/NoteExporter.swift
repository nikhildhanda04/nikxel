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
        case markdown, pdf, word

        var displayName: String {
            switch self {
            case .markdown: return "Markdown (.md)"
            case .pdf: return "PDF (.pdf)"
            case .word: return "Word (.docx)"
            }
        }

        var fileExtension: String {
            switch self {
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
        let attributed = try attributedString(from: markdown)

        switch format {
        case .markdown:
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

    /// Minimal Markdown-to-HTML for what the note prompts actually emit:
    /// headings, bullet and numbered lists, bold/italic/code, rules and
    /// paragraphs. Not a general Markdown implementation.
    static func html(from markdown: String) -> String {
        var out = ""
        var listKind: String?          // "ul" or "ol" while a list is open
        var inCodeBlock = false

        func closeList() {
            if let kind = listKind { out += "</\(kind)>\n"; listKind = nil }
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
                out += "<h\(level)>\(inline(text))</h\(level)>\n"
            } else if line == "---" || line == "***" || line == "___" {
                closeList()
                out += "<hr/>\n"
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                if listKind != "ul" { closeList(); out += "<ul>\n"; listKind = "ul" }
                out += "<li>\(inline(String(line.dropFirst(2))))</li>\n"
            } else if let match = numberedItem(line) {
                if listKind != "ol" { closeList(); out += "<ol>\n"; listKind = "ol" }
                out += "<li>\(inline(match))</li>\n"
            } else {
                closeList()
                out += "<p>\(inline(line))</p>\n"
            }
        }
        closeList()
        if inCodeBlock { out += "</pre>\n" }

        return """
        <html><head><meta charset="utf-8"><style>
        body { font-family: -apple-system, Helvetica, Arial, sans-serif; font-size: 11pt; line-height: 1.45; color: #111; }
        h1 { font-size: 20pt; } h2 { font-size: 15pt; } h3 { font-size: 12.5pt; }
        code, pre { font-family: Menlo, monospace; font-size: 10pt; background: #f4f4f4; }
        pre { padding: 6pt; } hr { border: 0; border-top: 1px solid #ccc; }
        </style></head><body>
        \(out)</body></html>
        """
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
