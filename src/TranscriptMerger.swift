import Foundation

struct TranscriptSegment {
    let start: Double
    let end: Double
    let text: String
    let speaker: String
}

enum TranscriptMerger {
    /// Parse SRT, interleave by start time, render labeled transcript:
    ///   [00:00:05] Me: ...
    ///   [00:00:12] Others: ...
    /// `speakers` (from MeetSpeakers) names the "Others" lines: each takes
    /// whoever Meet showed talking for most of it.
    static func merge(micSRT: URL?, sysSRT: URL?, speakers: [(start: Double, end: Double, name: String)] = []) -> String {
        var segments: [TranscriptSegment] = []
        if let url = micSRT {
            segments.append(contentsOf: parse(url: url, speaker: "Me"))
        }
        if let url = sysSRT {
            segments.append(contentsOf: parse(url: url, speaker: "Others"))
        }
        segments.sort { $0.start < $1.start }

        var lines: [String] = []
        for s in segments {
            let text = s.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let who = s.speaker == "Others" ? (named(s, speakers) ?? "Others") : s.speaker
            lines.append("[\(formatTimestamp(s.start))] \(who): \(text)")
        }
        return lines.joined(separator: "\n")
    }

    /// Who Meet showed talking for at least a quarter of the line.
    static func named(_ s: TranscriptSegment, _ speakers: [(start: Double, end: Double, name: String)]) -> String? {
        var overlap: [String: Double] = [:]
        for sp in speakers { overlap[sp.name, default: 0] += max(0, min(s.end, sp.end) - max(s.start, sp.start)) }
        guard let best = overlap.max(by: { $0.value < $1.value }), best.value >= max(0.5, (s.end - s.start) / 4) else { return nil }
        return best.key
    }

    static func parse(url: URL, speaker: String) -> [TranscriptSegment] {
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        // SRT blocks are separated by blank lines. Each block:
        //   <index>
        //   HH:MM:SS,mmm --> HH:MM:SS,mmm
        //   <text...>
        let blocks = raw.replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n\n")
        var out: [TranscriptSegment] = []
        for block in blocks {
            let lines = block.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            guard lines.count >= 2 else { continue }
            // Find the line with " --> " in it (skips index line; some emitters omit it).
            guard let tIdx = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let timeLine = lines[tIdx]
            let parts = timeLine.components(separatedBy: "-->")
            guard parts.count == 2,
                  let start = parseSRTTime(parts[0].trimmingCharacters(in: .whitespaces)),
                  let end = parseSRTTime(parts[1].trimmingCharacters(in: .whitespaces)) else { continue }
            let textLines = Array(lines.dropFirst(tIdx + 1))
            let text = textLines.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            out.append(TranscriptSegment(start: start, end: end, text: text, speaker: speaker))
        }
        return out
    }

    /// "HH:MM:SS,mmm" or "HH:MM:SS.mmm" -> seconds.
    private static func parseSRTTime(_ s: String) -> Double? {
        let normalized = s.replacingOccurrences(of: ",", with: ".")
        let comps = normalized.split(separator: ":")
        guard comps.count == 3,
              let h = Double(comps[0]),
              let m = Double(comps[1]),
              let sec = Double(comps[2]) else { return nil }
        return h * 3600 + m * 60 + sec
    }

    private static func formatTimestamp(_ seconds: Double) -> String {
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%02d:%02d:%02d", h, m, s)
        }
        return String(format: "%02d:%02d", m, s)
    }
}
