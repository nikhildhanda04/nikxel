import Foundation

class MOMGenerator {
    enum MOMError: Error {
        case opencodeNotFound
        case transcriptEmpty
        case generationFailed(String)
    }

    private var candidateBinaries: [String] {
        let home = NSHomeDirectory()
        return [
            "\(home)/.opencode/bin/opencode",
            "/opt/homebrew/bin/opencode",
            "/usr/local/bin/opencode"
        ]
    }

    private let promptsDir: URL
    private let workspace: URL
    private let notesDir: URL
    private let meetingsDir: URL

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let nikxel = home.appendingPathComponent(".nikxel", isDirectory: true)
        self.promptsDir = nikxel.appendingPathComponent("prompts", isDirectory: true)
        self.workspace = nikxel.appendingPathComponent("momworkspace", isDirectory: true)
        self.notesDir = home.appendingPathComponent("Documents/nikxel/notes", isDirectory: true)
        self.meetingsDir = home.appendingPathComponent("Documents/nikxel/meetings", isDirectory: true)

        try? FileManager.default.createDirectory(at: promptsDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: notesDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: meetingsDir, withIntermediateDirectories: true)
        seedDefaultPrompts()
    }

    func generate(transcript: String, mode: CaptureMode, startedAt: Date, durationSec: Int, completion: @escaping (Result<URL, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            do {
                let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.split(whereSeparator: { $0.isWhitespace }).count < 3 {
                    throw MOMError.transcriptEmpty
                }
                guard let bin = self.findOpencode() else { throw MOMError.opencodeNotFound }
                let output = try self.runOpencode(binary: bin, mode: mode, transcript: trimmed, startedAt: startedAt, durationSec: durationSec)
                let outURL = try self.saveOutput(content: output, mode: mode, startedAt: startedAt)
                completion(.success(outURL))
            } catch {
                completion(.failure(error))
            }
        }
    }

    private func findOpencode() -> String? {
        for path in candidateBinaries where FileManager.default.isExecutableFile(atPath: path) { return path }
        let task = Process()
        task.launchPath = "/bin/zsh"
        task.arguments = ["-ilc", "which opencode 2>/dev/null"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do { try task.run() } catch { return nil }
        task.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let p = path, !p.isEmpty, FileManager.default.isExecutableFile(atPath: p) { return p }
        return nil
    }

    private func promptPath(for mode: CaptureMode) -> URL {
        let name = mode == .notes ? "notes.md" : "meeting.md"
        return promptsDir.appendingPathComponent(name)
    }

    private func runOpencode(binary: String, mode: CaptureMode, transcript: String, startedAt: Date, durationSec: Int) throws -> String {
        let promptURL = promptPath(for: mode)
        let template = (try? String(contentsOf: promptURL, encoding: .utf8)) ?? defaultPrompt(for: mode)

        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH:mm"
        let prompt = template
            .replacingOccurrences(of: "{{date}}", with: fmt.string(from: startedAt))
            .replacingOccurrences(of: "{{duration}}", with: "\(durationSec / 60) min \(durationSec % 60) sec")
            .replacingOccurrences(of: "{{transcript}}", with: transcript)

        let promptDump = workspace.appendingPathComponent("last_prompt.txt")
        let stdoutDump = workspace.appendingPathComponent("last_stdout.log")
        let stderrDump = workspace.appendingPathComponent("last_stderr.log")
        try? prompt.write(to: promptDump, atomically: true, encoding: .utf8)

        let inPipe = Pipe()
        let outPipe = Pipe()
        let errPipe = Pipe()

        let task = Process()
        task.executableURL = URL(fileURLWithPath: binary)
        task.currentDirectoryURL = workspace
        task.arguments = ["run"]
        var env = ProcessInfo.processInfo.environment
        let extraPaths = ["\(NSHomeDirectory())/.opencode/bin", "/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin"]
        env["PATH"] = (extraPaths + [env["PATH"] ?? ""]).filter { !$0.isEmpty }.joined(separator: ":")
        task.environment = env
        task.standardInput = inPipe
        task.standardOutput = outPipe
        task.standardError = errPipe
        try task.run()

        if let data = prompt.data(using: .utf8) {
            inPipe.fileHandleForWriting.write(data)
        }
        inPipe.fileHandleForWriting.closeFile()
        task.waitUntilExit()

        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        try? outData.write(to: stdoutDump)
        try? errData.write(to: stderrDump)

        guard task.terminationStatus == 0 else {
            let errStr = String(data: errData, encoding: .utf8) ?? "exit \(task.terminationStatus)"
            let snippet = errStr.isEmpty ? "(no stderr; exit \(task.terminationStatus))" : String(errStr.prefix(500))
            throw MOMError.generationFailed("\(snippet)\n\nLogs: \(workspace.path)")
        }
        guard let out = String(data: outData, encoding: .utf8) else {
            throw MOMError.generationFailed("non-utf8 output\n\nLogs: \(workspace.path)")
        }
        let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            let errStr = String(data: errData, encoding: .utf8) ?? ""
            throw MOMError.generationFailed("empty output from opencode\n\(errStr.prefix(300))\n\nLogs: \(workspace.path)")
        }
        return out
    }

    private func saveOutput(content: String, mode: CaptureMode, startedAt: Date) throws -> URL {
        let dir = mode == .notes ? notesDir : meetingsDir
        let fmt = DateFormatter()
        // Seconds in the stem so two recordings started in the same minute don't
        // overwrite each other's MOM file.
        fmt.dateFormat = "yyyy-MM-dd-HHmmss"
        let name = "\(fmt.string(from: startedAt)).md"
        let url = dir.appendingPathComponent(name)
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func seedDefaultPrompts() {
        for mode: CaptureMode in [.notes, .meeting] {
            let url = promptPath(for: mode)
            if FileManager.default.fileExists(atPath: url.path) { continue }
            try? defaultPrompt(for: mode).write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private func defaultPrompt(for mode: CaptureMode) -> String {
        switch mode {
        case .notes: return notesPrompt
        case .meeting: return meetingPrompt
        }
    }

    private let notesPrompt = """
You are generating structured notes from the transcript of a YouTube video,
lecture, podcast, talk, or other single-source spoken content. Always produce
the Markdown below — never refuse or output a "not enough content" message.

The transcript may be in English, Hindi, Hinglish (mixed), or any other
language. Write the notes in the SAME language as the transcript. If mixed,
match the dominant language.

Recorded: {{date}}
Duration: {{duration}}

Output this exact Markdown structure (translate the section headings to match
the transcript language):

# Notes — {{date}}

## Summary
2-4 sentences capturing what this content is about and its main thrust.

## Key Points
- The substantive ideas, claims, arguments, facts, or topics covered.
- Be specific. Quote numbers, names, examples, and concrete claims where they appear.
- Cover the full arc of the content, not just the opening.

## Notable Quotes / Examples
- Direct quotes, vivid examples, or stories the speaker used to make a point.
- If none stand out, write "- None." — don't skip the section.

## Open Questions
- Unresolved questions, things to look up, or topics flagged for later.
- If none, write "- None." — don't skip the section.

Rules:
- Never invent claims, numbers, or quotes not in the transcript.
- If the transcript is short or sparse, still produce all four sections —
  scale the content to the source.
- Output ONLY the Markdown — no preamble, no closing remarks, no commentary.

---
TRANSCRIPT:
{{transcript}}
"""

    private let meetingPrompt = """
You are generating Minutes of Meeting (MOM) from a transcript of a meeting,
call, or 1:1 conversation. The transcript is pre-labeled with speakers:
  "Me" = the user who recorded this meeting (microphone input)
  "Others" = everyone else on the call (system audio output)
Multiple distinct people may be collapsed under "Others" — use context clues
(names, turn-taking, topic switches) to distinguish them where you can.

Always produce the Markdown below — never refuse or output a "not a real
meeting" message.

The transcript may be in English, Hindi, Hinglish (mixed), or any other
language. Write the MOM in the SAME language as the transcript.

Recorded: {{date}}
Duration: {{duration}}

Output this exact Markdown structure (translate the section headings to match
the transcript language):

# Meeting — {{date}}

## Attendees
- Me — (infer role/context if possible)
- Others — list distinct participants you can identify by name or context; if
  indistinguishable, write "Others (1 or more participants)".

## Summary
3-5 sentences capturing what was discussed and the overall outcome.

## Per-Speaker Highlights
**Me:** what the user contributed, asked, proposed, or committed to.
**Others:** what the other side contributed, asked, proposed, or committed to.
  If you identified specific people by name, give each their own line.

## Decisions
- Concrete decisions made during the meeting. If none, write "- None."

## Action Items
- [ ] Task — Owner (Me / name from Others) — due date if mentioned.
- If none, write "- None mentioned."

## Open Questions
- Unresolved questions or follow-ups flagged for later. If none, write "- None."

Rules:
- Never invent attendees, decisions, owners, or commitments not in the transcript.
- Attribute action items to the speaker who took them on.
- Output ONLY the Markdown — no preamble, no closing remarks, no commentary.

---
TRANSCRIPT (labeled by speaker):
{{transcript}}
"""
}
