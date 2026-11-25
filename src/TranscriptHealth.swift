import Foundation

/// One log line on how a whisper transcript came out, so a meeting that
/// turned into nothing can be traced afterwards: how many segments and words,
/// how many segments are only a placeholder ("[no audio]", "[BLANK_AUDIO]",
/// "(music)"), the line repeated most, and the longest run of the same line --
/// the signature of whisper stuck in a loop (2026-11-25: "[no audio]" for 280
/// segments of a 55-minute meeting full of speech). Foundation only, mirrored
/// by windows/src/main/recording/transcriptHealth.ts; checks/check_transcript_health.swift.
enum TranscriptHealth {
    struct Report: Equatable {
        var segments = 0, words = 0, placeholders = 0
        var topPlaceholder = "", topLine = "", topLineCount = 0
        var longestRun = 0, runLine = ""
    }

    /// The spoken lines of an .srt or .txt: no cue numbers, no timestamps, no blanks.
    static func lines(_ text: String) -> [String] {
        text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.contains("-->") && Int($0) == nil }
    }

    static func isPlaceholder(_ line: String) -> Bool {
        line.range(of: #"^([\[(][^\])]*[\])]\s*)+$"#, options: .regularExpression) != nil
    }

    static func analyse(_ text: String) -> Report {
        var r = Report(), counts: [String: Int] = [:], placeholderCounts: [String: Int] = [:]
        var run = 0, previous = ""
        for line in lines(text) {
            r.segments += 1
            if isPlaceholder(line) {
                r.placeholders += 1
                placeholderCounts[line, default: 0] += 1
            } else {
                r.words += line.replacingOccurrences(of: #"\[[^\]]*\]|\([^)]*\)"#, with: " ", options: .regularExpression)
                    .split(whereSeparator: { $0.isWhitespace }).count
                counts[line.lowercased(), default: 0] += 1
            }
            run = line == previous ? run + 1 : 1
            previous = line
            if run > r.longestRun { r.longestRun = run; r.runLine = line }
        }
        if let top = placeholderCounts.max(by: { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) }) { r.topPlaceholder = top.key }
        if let top = counts.max(by: { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) }) { r.topLine = top.key; r.topLineCount = top.value }
        return r
    }

    /// "280 segments, 3 words, 277 placeholders (mostly "[no audio]"), top line "hello." ×3, longest run 30× "[no audio]""
    static func describe(_ text: String) -> String {
        let r = analyse(text)
        var s = "\(r.segments) segments, \(r.words) words"
        if r.placeholders > 0 { s += ", \(r.placeholders) placeholders (mostly \"\(r.topPlaceholder)\")" }
        if r.topLineCount > 1 { s += ", top line \"\(r.topLine.prefix(60))\" ×\(r.topLineCount)" }
        if r.longestRun > 2 { s += ", longest run \(r.longestRun)× \"\(r.runLine.prefix(60))\"" }
        return s
    }
}
