import AppKit
import PDFKit
import Vision

/// Files the user hands Nikxel: dropped on (or + in) the chat, or attached to an automation, like
/// the SOP format to follow after every client meeting. Each is kept in ~/.nikxel/files/<id>/ with
/// the text read out of it (.text), which is all the chat and automations ever see: PDF, Word,
/// RTF and text files, and an image's words through on-device OCR. Never uploaded.
/// Mirrors windows/src/main/system/attachments.ts.
enum Attachments {
    static var dir = URL(fileURLWithPath: NSHomeDirectory() + "/.nikxel/files")
    static let cap = 40_000          // characters of one file a prompt gets
    static let maxBytes = 15_000_000

    /// Saves a file and reads its text: {id, name, chars}, or {error} to show.
    static func add(name: String, data: Data) -> [String: Any] {
        guard data.count <= maxBytes else { return ["error": "\(name) is over 15 MB."] }
        let safe = String((name as NSString).lastPathComponent.drop { $0 == "." }.prefix(120))
        let id = UUID().uuidString, folder = dir.appendingPathComponent(id), file = folder.appendingPathComponent(safe.isEmpty ? "file" : safe)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: file)
        } catch { return ["error": "Couldn’t save \(name)."] }
        let text = String(extract(file).trimmingCharacters(in: .whitespacesAndNewlines).prefix(cap))
        guard !text.isEmpty else {
            try? FileManager.default.removeItem(at: folder)
            return ["error": "I couldn’t read any text in \(safe). Try a PDF, Word, text file or a clear image."]
        }
        try? text.write(to: folder.appendingPathComponent(".text"), atomically: true, encoding: .utf8)
        cblog("Attachments: read \(text.count) chars from a .\(file.pathExtension.lowercased()) file")
        return ["id": id, "name": file.lastPathComponent, "chars": text.count]
    }

    static func add(url: URL) -> [String: Any] {
        guard let data = try? Data(contentsOf: url) else { return ["error": "Couldn’t open \(url.lastPathComponent)."] }
        return add(name: url.lastPathComponent, data: data)
    }

    static let imageTypes: Set<String> = ["png", "jpg", "jpeg", "heic", "gif", "tif", "tiff", "bmp", "webp"]

    static func extract(_ url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        if ext == "pdf" { return PDFDocument(url: url)?.string ?? "" }
        if imageTypes.contains(ext) { return ocr(url) }
        if ["docx", "doc", "rtf", "odt", "wordml"].contains(ext) {
            return (try? NSAttributedString(url: url, options: [:], documentAttributes: nil))?.string ?? ""
        }
        let raw = (try? String(contentsOf: url, encoding: .utf8)) ?? (try? String(contentsOf: url, encoding: .isoLatin1)) ?? ""
        if raw.contains("\u{0}") { return "" } // a binary file we can't read, not text
        // HTML: the words, not the tags (NSAttributedString's HTML reader needs the main thread).
        return ["html", "htm"].contains(ext) ? raw.replacingOccurrences(of: #"<(script|style)[\s\S]*?</\1>|<[^>]+>"#, with: " ", options: .regularExpression) : raw
    }

    /// The words in an image, read on this Mac.
    static func ocr(_ url: URL) -> String {
        guard let img = NSImage(contentsOf: url)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return "" }
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate
        try? VNImageRequestHandler(cgImage: img).perform([req])
        let lines = (req.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        return lines.isEmpty ? "" : "(The words in the image \(url.lastPathComponent), read by OCR.)\n" + lines.joined(separator: "\n")
    }

    /// The file's name, nil when it's gone (or `id` isn't one of ours).
    static func name(_ id: String) -> String? {
        guard UUID(uuidString: id) != nil else { return nil }
        return (try? FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent(id).path))?.first { !$0.hasPrefix(".") }
    }

    /// One file as a prompt block, nil when it's gone.
    static func block(_ id: String, heading: String = "a file the user attached") -> String? {
        guard let name = name(id),
              let text = try? String(contentsOf: dir.appendingPathComponent(id).appendingPathComponent(".text"), encoding: .utf8) else { return nil }
        return "### \(heading): \(name)\n\(text)"
    }
}
