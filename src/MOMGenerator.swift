import Foundation

// Lets the stdout/stderr pump threads hand their bytes back without a data race.
private final class OutputBuffer {
    private let lock = NSLock()
    private var _out = Data()
    private var _err = Data()
    var out: Data { lock.lock(); defer { lock.unlock() }; return _out }
    var err: Data { lock.lock(); defer { lock.unlock() }; return _err }
    func setOut(_ d: Data) { lock.lock(); _out = d; lock.unlock() }
    func setErr(_ d: Data) { lock.lock(); _err = d; lock.unlock() }
}

class MOMGenerator {
    enum MOMError: Error {
        case agentNotFound
        case transcriptEmpty
        case generationFailed(String)
    }

    private var candidateBinaries: [String] {
        let home = NSHomeDirectory()
        return [
            "/opt/homebrew/bin/claude",
            "\(home)/.claude/local/claude",
            "\(home)/.local/bin/claude",
            "/usr/local/bin/claude"
        ]
    }

    // Upper bound on a single claude run. Generation normally takes well under
    // a minute; anything past this is a hang, not slow work.
    private static let timeoutSec: Double = 600

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
                // Save the raw transcript before attempting generation, so a
                // claude failure/timeout/missing-binary still leaves the full
                // transcript on disk instead of losing it with the recording.
                try? self.saveTranscript(content: trimmed, mode: mode, startedAt: startedAt)
                guard let bin = self.findClaude() else { throw MOMError.agentNotFound }
                let output = try self.runTemplate(binary: bin, mode: mode, transcript: trimmed, startedAt: startedAt, durationSec: durationSec)
                let outURL = try self.saveOutput(content: output, mode: mode, startedAt: startedAt)
                completion(.success(outURL))
            } catch {
                completion(.failure(error))
            }
        }
    }

    private func findClaude() -> String? {
        for path in candidateBinaries where FileManager.default.isExecutableFile(atPath: path) { return path }
        let task = Process()
        task.launchPath = "/bin/zsh"
        task.arguments = ["-ilc", "which claude 2>/dev/null"]
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

    private func runTemplate(binary: String, mode: CaptureMode, transcript: String, startedAt: Date, durationSec: Int) throws -> String {
        let promptURL = promptPath(for: mode)
        let template = (try? String(contentsOf: promptURL, encoding: .utf8)) ?? defaultPrompt(for: mode)

        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH:mm"
        let prompt = template
            .replacingOccurrences(of: "{{date}}", with: fmt.string(from: startedAt))
            .replacingOccurrences(of: "{{duration}}", with: "\(durationSec / 60) min \(durationSec % 60) sec")
            .replacingOccurrences(of: "{{transcript}}", with: transcript)
            .replacingOccurrences(of: "{{language_instruction}}", with: NikxelSettings.languageInstruction)
            .replacingOccurrences(of: "{{user_name}}", with: NikxelSettings.userName)

        return try executeClaude(binary: binary, prompt: prompt)
    }

    // Run an arbitrary prompt through the agent. Used by DayLogger for EOD
    // summaries and by LLMResponder for chat replies.
    func runPrompt(_ prompt: String) throws -> String {
        guard let bin = findClaude() else { throw MOMError.agentNotFound }
        return try executeClaude(binary: bin, prompt: prompt)
    }

    private func executeClaude(binary: String, prompt: String) throws -> String {
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
        // -p is headless one-shot. Empty --allowed-tools keeps it pure text
        // generation: these prompts need no file or shell access, and a tool
        // call that stops for a permission prompt would hang a GUI-spawned
        // process with nobody to answer it.
        task.arguments = ["-p", "--allowed-tools", ""]
        var env = ProcessInfo.processInfo.environment
        let extraPaths = ["/opt/homebrew/bin", "\(NSHomeDirectory())/.claude/local", "\(NSHomeDirectory())/.local/bin", "/usr/local/bin", "/opt/local/bin"]
        env["PATH"] = (extraPaths + [env["PATH"] ?? ""]).filter { !$0.isEmpty }.joined(separator: ":")
        task.environment = env
        task.standardInput = inPipe
        task.standardOutput = outPipe
        task.standardError = errPipe
        let exited = DispatchSemaphore(value: 0)
        task.terminationHandler = { _ in exited.signal() }
        try task.run()

        // Drain both pipes and feed stdin on their own threads. Reading only
        // after the process exits deadlocks once opencode emits more than the
        // 64 KB pipe buffer, and a long transcript can fill stdin's buffer the
        // same way.
        let buf = OutputBuffer()
        let io = DispatchGroup()
        func pump(_ handle: FileHandle, _ keep: @escaping (OutputBuffer, Data) -> Void) {
            io.enter()
            DispatchQueue.global(qos: .utility).async {
                let d = handle.readDataToEndOfFile()
                keep(buf, d)
                io.leave()
            }
        }
        pump(outPipe.fileHandleForReading) { $0.setOut($1) }
        pump(errPipe.fileHandleForReading) { $0.setErr($1) }
        DispatchQueue.global(qos: .utility).async {
            if let data = prompt.data(using: .utf8) {
                try? inPipe.fileHandleForWriting.write(contentsOf: data)
            }
            try? inPipe.fileHandleForWriting.close()
        }

        // Without this the pet sits in .writingMOM forever whenever the agent
        // hangs (opencode used to retry a failing stream with backoff and never
        // exit), so no alert ever fires and the animation never stops.
        // ponytail: fixed ceiling; make it a setting if a long transcript ever
        // legitimately runs past it.
        var timedOut = false
        if exited.wait(timeout: .now() + Self.timeoutSec) == .timedOut {
            timedOut = true
            task.terminate()
            _ = exited.wait(timeout: .now() + 5)
        }
        // Bounded: a lingering grandchild can hold the write end open past the
        // kill, and waiting forever here would reintroduce the same stall.
        _ = io.wait(timeout: .now() + 10)
        let outData = buf.out
        let errData = buf.err
        try? outData.write(to: stdoutDump)
        try? errData.write(to: stderrDump)

        if timedOut {
            throw MOMError.generationFailed("claude did not finish within \(Int(Self.timeoutSec / 60)) min and was killed.\nCheck that `claude -p` works in a terminal (login / quota).\n\(String((String(data: errData, encoding: .utf8) ?? "").suffix(300)))\n\nLogs: \(workspace.path)")
        }

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
        let name = "\(timestampStem(startedAt)).md"
        let url = dir.appendingPathComponent(name)
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // Written before generation runs, so the full transcript survives even if
    // claude is missing, times out, or returns an error. Shares its filename
    // stem with saveOutput's .md so the two are easy to pair up by eye.
    @discardableResult
    private func saveTranscript(content: String, mode: CaptureMode, startedAt: Date) throws -> URL {
        let dir = mode == .notes ? notesDir : meetingsDir
        let name = "\(timestampStem(startedAt)).transcript.txt"
        let url = dir.appendingPathComponent(name)
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // Seconds in the stem so two recordings started in the same minute don't
    // overwrite each other's files.
    private func timestampStem(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd-HHmmss"
        return fmt.string(from: date)
    }

    private func seedDefaultPrompts() {
        for mode: CaptureMode in [.notes, .meeting] {
            let url = promptPath(for: mode)
            let fresh = defaultPrompt(for: mode)
            if let existing = try? String(contentsOf: url, encoding: .utf8) {
                // Migrate older default prompts that told the model to write in
                // the transcript's language. These produced Hindi notes/MOM
                // for Hindi recordings and false "no credible conversation"
                // bail-outs. Detect by the old marker phrases and overwrite.
                // User customizations that don't contain these phrases are
                // left alone.
                let legacyMarkers = [
                    "Write the notes in the SAME language as the transcript",
                    "Write the MOM in the SAME language as the transcript",
                    "translate the section headings to match",
                    "ALWAYS write the notes in English regardless of the transcript",
                    "ALWAYS write the MOM in English regardless of the transcript"
                ]
                if legacyMarkers.contains(where: { existing.contains($0) }) {
                    try? fresh.write(to: url, atomically: true, encoding: .utf8)
                }
                continue
            }
            try? fresh.write(to: url, atomically: true, encoding: .utf8)
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

{{language_instruction}}
Section headings (Summary, Key Points, etc.) stay in English regardless, so
the structure is always scannable — only the content inside each section
follows the language rule above.

Recorded: {{date}}
Duration: {{duration}}

Output this exact Markdown structure (keep section headings in English):

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
  "Me" = {{user_name}}, the user who recorded this meeting (microphone input)
  "Others" = everyone else on the call (system audio output)

IMPORTANT identity rule: "Me" is specifically {{user_name}} — nobody else.
If a name mentioned anywhere in the transcript happens to resemble, sound
like, or be associated with someone else on the call, do NOT reassign "Me"'s
lines to them, and do NOT describe "Me" as if they were a different person.
Conversely, don't attribute something "Others" said to {{user_name}}/"Me"
just because the topic involves {{user_name}}. When referring to the user by
name anywhere in the output, use {{user_name}}, not a guessed or inferred name.
Multiple distinct people may be collapsed under "Others" — use context clues
(names, turn-taking, topic switches) to distinguish them where you can.

Always produce the Markdown below — never refuse, never output a "not a real
meeting" message, and never claim "no credible conversation occurred" or any
similar bail-out. If the transcript has any speech at all, treat it as a real
meeting and fill in every section from what was said. A short, casual, or
non-English meeting is still a meeting.

{{language_instruction}}
Section headings (Attendees, Summary, Decisions, etc.) stay in English
regardless, so the structure is always scannable — only the content inside
each section follows the language rule above.

Recorded: {{date}}
Duration: {{duration}}

Output this exact Markdown structure (keep section headings in English):

# Meeting — {{date}}

## Attendees
- {{user_name}} (Me) — (infer role/context if possible)
- Others — list distinct participants you can identify by name or context; if
  indistinguishable, write "Others (1 or more participants)".

## Summary
3-5 sentences capturing what was discussed and the overall outcome.

## Per-Speaker Highlights
**{{user_name}} (Me):** what the user contributed, asked, proposed, or committed to.
**Others:** what the other side contributed, asked, proposed, or committed to.
  If you identified specific people by name, give each their own line.

## Decisions
- Concrete decisions made during the meeting. If none, write "- None."

## Action Items
- [ ] Task — Owner ({{user_name}} / name from Others) — due date if mentioned.
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
