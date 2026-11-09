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

// Per-agent CLI shape: where to find the binary, how to invoke it for a
// one-shot headless text-generation prompt, and how to pull plain text back
// out of whatever format that agent prints.
private struct AgentBackend {
    let candidatePaths: (String) -> [String]
    let whichName: String
    let buildArgs: (String) -> [String]
    let usesStdin: Bool
    let parseOutput: (Data) -> String?

    static func backend(for agent: CodingAgent) -> AgentBackend {
        switch agent {
        case .claude:
            return AgentBackend(
                candidatePaths: { home in [
                    "/opt/homebrew/bin/claude",
                    "\(home)/.claude/local/claude",
                    "\(home)/.local/bin/claude",
                    "/usr/local/bin/claude"
                ]},
                whichName: "claude",
                // -p is headless one-shot. Empty --allowed-tools keeps it pure
                // text generation: these prompts need no file or shell access,
                // and a tool call that stops for a permission prompt would
                // hang a GUI-spawned process with nobody to answer it.
                buildArgs: { _ in ["-p", "--allowed-tools", ""] },
                usesStdin: true,
                parseOutput: { String(data: $0, encoding: .utf8) }
            )
        case .opencode:
            return AgentBackend(
                candidatePaths: { home in [
                    "\(home)/.opencode/bin/opencode",
                    "/opt/homebrew/bin/opencode",
                    "\(home)/.local/bin/opencode",
                    "/usr/local/bin/opencode"
                ]},
                whichName: "opencode",
                // `opencode run` takes the message as a positional arg, not
                // stdin. --format json gives newline-delimited event objects
                // instead of the human-readable banner + reply that the
                // default format prints (which would pollute the saved .md).
                buildArgs: { prompt in ["run", prompt, "--format", "json"] },
                usesStdin: false,
                parseOutput: parseOpenCodeNDJSON
            )
        case .codex:
            // `codex exec <prompt>` is the expected non-interactive shape,
            // but this is UNVERIFIED — the local codex install is broken
            // (missing @openai/codex-darwin-arm64), so there was no working
            // binary to test the exact flags/output format against. Confirm
            // and adjust once a working codex CLI is available.
            return AgentBackend(
                candidatePaths: { home in [
                    "/opt/homebrew/bin/codex",
                    "\(home)/.local/bin/codex",
                    "/usr/local/bin/codex"
                ]},
                whichName: "codex",
                buildArgs: { prompt in ["exec", prompt] },
                usesStdin: false,
                parseOutput: { String(data: $0, encoding: .utf8) }
            )
        }
    }

    // opencode's --format json prints one JSON object per line; the reply
    // text is spread across one or more {"type":"text",...} events.
    private static func parseOpenCodeNDJSON(_ data: Data) -> String? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        var out = ""
        for line in text.split(separator: "\n") {
            guard let lineData = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  obj["type"] as? String == "text",
                  let part = obj["part"] as? [String: Any],
                  let t = part["text"] as? String else { continue }
            out += t
        }
        return out.isEmpty ? nil : out
    }
}

class MOMGenerator {
    enum MOMError: Error {
        case agentNotFound
        case transcriptEmpty
        case generationFailed(String)
    }

    // Upper bound on a single agent run. Generation normally takes well under
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
                let transcriptURL = try? self.saveTranscript(content: trimmed, mode: mode, startedAt: startedAt)

                // Record that a summary is owed for this transcript. Deleted on
                // success; anything left behind is an unfinished job that
                // "Regenerate Unfinished Summary" can pick up later -- including
                // after a crash or a quit mid-generation.
                let stem = self.timestampStem(startedAt)
                self.writeMarker(stem: stem, mode: mode, startedAt: startedAt,
                                 durationSec: durationSec, transcript: transcriptURL)

                let agent = NikxelSettings.connectedAgent
                guard let bin = self.findBinary(for: agent) else { throw MOMError.agentNotFound }
                let runDir = self.workspace.appendingPathComponent(stem, isDirectory: true)
                let output = try self.runTemplate(binary: bin, agent: agent, mode: mode, transcript: trimmed, startedAt: startedAt, durationSec: durationSec, runDir: runDir)
                let outURL = try self.saveOutput(content: output, mode: mode, startedAt: startedAt)
                self.clearMarker(stem: stem)
                completion(.success(outURL))
            } catch {
                completion(.failure(error))
            }
        }
    }

    // Resolves the installed binary for `agent`, checking common install
    // locations first and falling back to a login-shell `which` (same
    // approach for every agent — only the candidate paths/binary name differ).
    func findBinary(for agent: CodingAgent) -> String? {
        let backend = AgentBackend.backend(for: agent)
        let home = NSHomeDirectory()
        for path in backend.candidatePaths(home) where FileManager.default.isExecutableFile(atPath: path) { return path }
        let task = Process()
        task.launchPath = "/bin/zsh"
        task.arguments = ["-ilc", "which \(backend.whichName) 2>/dev/null"]
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

    private func runTemplate(binary: String, agent: CodingAgent, mode: CaptureMode, transcript: String, startedAt: Date, durationSec: Int, runDir: URL) throws -> String {
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
            .replacingOccurrences(of: "{{custom_instructions}}", with: NikxelSettings.summaryStyleInstruction)

        return try executeAgent(binary: binary, agent: agent, prompt: prompt, runDir: runDir)
    }

    // Run an arbitrary prompt through the agent. Used by DayLogger for EOD
    // summaries and by LLMResponder for chat replies.
    func runPrompt(_ prompt: String) throws -> String {
        let agent = NikxelSettings.connectedAgent
        guard let bin = findBinary(for: agent) else { throw MOMError.agentNotFound }
        return try executeAgent(binary: bin, agent: agent, prompt: prompt)
    }

    private func executeAgent(binary: String, agent: CodingAgent, prompt: String, runDir: URL? = nil) throws -> String {
        // Each run gets its own directory. These used to be fixed names in one
        // shared folder, so two overlapping runs -- easy to trigger by starting
        // a second recording while the first was still summarizing -- wiped
        // each other's logs, leaving nothing to diagnose a failure with.
        let workspace = runDir ?? self.workspace
        try? FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let backend = AgentBackend.backend(for: agent)
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
        task.arguments = backend.buildArgs(prompt)
        var env = ProcessInfo.processInfo.environment
        let extraPaths = ["/opt/homebrew/bin", "\(NSHomeDirectory())/.claude/local", "\(NSHomeDirectory())/.opencode/bin", "\(NSHomeDirectory())/.local/bin", "/usr/local/bin", "/opt/local/bin"]
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
            if backend.usesStdin, let data = prompt.data(using: .utf8) {
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
            throw MOMError.generationFailed("\(backend.whichName) did not finish within \(Int(Self.timeoutSec / 60)) min and was killed.\nCheck that `\(backend.whichName)` works in a terminal (login / quota).\n\(String((String(data: errData, encoding: .utf8) ?? "").suffix(300)))\n\nLogs: \(workspace.path)")
        }

        guard task.terminationStatus == 0 else {
            let errStr = String(data: errData, encoding: .utf8) ?? "exit \(task.terminationStatus)"
            let snippet = errStr.isEmpty ? "(no stderr; exit \(task.terminationStatus))" : String(errStr.prefix(500))
            throw MOMError.generationFailed("\(snippet)\n\nLogs: \(workspace.path)")
        }
        guard let out = backend.parseOutput(outData) else {
            throw MOMError.generationFailed("non-utf8 or unparseable output\n\nLogs: \(workspace.path)")
        }
        let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            let errStr = String(data: errData, encoding: .utf8) ?? ""
            throw MOMError.generationFailed("empty output from \(backend.whichName)\n\(errStr.prefix(300))\n\nLogs: \(workspace.path)")
        }
        return out
    }

    private func saveOutput(content: String, mode: CaptureMode, startedAt: Date) throws -> URL {
        let dir = mode == .notes ? notesDir : meetingsDir
        let name = "\(timestampStem(startedAt)).md"
        let url = dir.appendingPathComponent(name)
        try content.write(to: url, atomically: true, encoding: .utf8)

        // Always keep the Markdown -- it's what the agent produced and what the
        // other formats render from. A failed conversion shouldn't lose the
        // note, so fall back to handing back the .md.
        let format = NikxelSettings.noteFormat
        guard format != .markdown else { return url }
        do {
            return try NoteExporter.export(markdown: content, from: url, as: format)
        } catch {
            Diag.log("MOM", "note export to \(format.rawValue) failed: \(error)")
            return url
        }
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

    // MARK: - Unfinished jobs

    /// A summary that was started but never written.
    struct PendingJob {
        let stem: String
        let mode: CaptureMode
        let startedAt: Date
        let durationSec: Int
        let transcriptURL: URL
    }

    private var pendingDir: URL {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".nikxel/pending", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func writeMarker(stem: String, mode: CaptureMode, startedAt: Date, durationSec: Int, transcript: URL?) {
        guard let transcript = transcript else { return }
        let payload: [String: Any] = [
            "mode": mode == .notes ? "notes" : "meeting",
            "startedAt": startedAt.timeIntervalSince1970,
            "durationSec": durationSec,
            "transcript": transcript.path,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        try? data.write(to: pendingDir.appendingPathComponent("\(stem).json"))
    }

    private func clearMarker(stem: String) {
        try? FileManager.default.removeItem(at: pendingDir.appendingPathComponent("\(stem).json"))
    }

    /// Summaries that were started but never finished, newest first. A marker
    /// whose transcript has since vanished is dropped rather than reported.
    func unfinishedJobs() -> [PendingJob] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: pendingDir.path) else { return [] }
        var jobs: [PendingJob] = []
        for name in names where name.hasSuffix(".json") {
            let url = pendingDir.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let modeRaw = obj["mode"] as? String,
                  let started = obj["startedAt"] as? TimeInterval,
                  let duration = obj["durationSec"] as? Int,
                  let path = obj["transcript"] as? String else { continue }
            guard fm.isReadableFile(atPath: path) else { try? fm.removeItem(at: url); continue }
            jobs.append(PendingJob(
                stem: String(name.dropLast(5)),
                mode: modeRaw == "notes" ? .notes : .meeting,
                startedAt: Date(timeIntervalSince1970: started),
                durationSec: duration,
                transcriptURL: URL(fileURLWithPath: path)
            ))
        }
        return jobs.sorted { $0.startedAt > $1.startedAt }
    }

    /// Re-runs generation from a saved transcript.
    func regenerate(_ job: PendingJob, completion: @escaping (Result<URL, Error>) -> Void) {
        guard let transcript = try? String(contentsOf: job.transcriptURL, encoding: .utf8) else {
            completion(.failure(MOMError.transcriptEmpty))
            return
        }
        generate(transcript: transcript, mode: job.mode, startedAt: job.startedAt,
                 durationSec: job.durationSec, completion: completion)
    }

    /// Bumped whenever the shipped prompts change in a way existing installs
    /// need. Every default prompt carries it as `promptVersionTag`, so an
    /// out-of-date copy in ~/.nikxel/prompts/ is replaced on next launch.
    static let promptVersion = 5

    private static let versionTagPrefix = "<!-- nikxel-prompt v"
    static var promptVersionTag: String { "\(versionTagPrefix)\(promptVersion) -->" }

    /// The version stamped into an on-disk prompt, or nil if it predates
    /// versioning (or the user removed the tag, which opts them out).
    static func stampedVersion(_ text: String) -> Int? {
        guard let r = text.range(of: Self.versionTagPrefix),
              let end = text.range(of: " -->", range: r.upperBound..<text.endIndex)
        else { return nil }
        return Int(text[r.upperBound..<end.lowerBound])
    }

    private func seedDefaultPrompts() {
        for mode: CaptureMode in [.notes, .meeting] {
            let url = promptPath(for: mode)
            let fresh = defaultPrompt(for: mode)
            guard let existing = try? String(contentsOf: url, encoding: .utf8) else {
                try? fresh.write(to: url, atomically: true, encoding: .utf8)
                continue
            }
            if let stamped = Self.stampedVersion(existing) {
                // Versioned copy: replace only when it is behind. A user who
                // edited the prompt but kept the tag still gets updates; one
                // who deleted the tag is treated as having customized it.
                if stamped < Self.promptVersion {
                    try? fresh.write(to: url, atomically: true, encoding: .utf8)
                }
                continue
            }
            // Pre-versioning copies, identified by phrases unique to the
            // defaults that shipped before the tag existed. The first three
            // told the model to write in the transcript's language, which
            // produced Hindi notes and false "no credible conversation"
            // bail-outs; the last is the MOM prompt that collapsed every
            // remote participant into a single "Others".
            let legacyMarkers = [
                "Write the notes in the SAME language as the transcript",
                "Write the MOM in the SAME language as the transcript",
                "translate the section headings to match",
                "ALWAYS write the notes in English regardless of the transcript",
                "ALWAYS write the MOM in English regardless of the transcript",
                "IMPORTANT identity rule:",
                "## How to read this transcript"
            ]
            if legacyMarkers.contains(where: { existing.contains($0) }) {
                try? fresh.write(to: url, atomically: true, encoding: .utf8)
            }
        }
    }

    private func defaultPrompt(for mode: CaptureMode) -> String {
        switch mode {
        case .notes: return notesPrompt
        case .meeting: return meetingPrompt
        }
    }

    private let notesPrompt = """
\(MOMGenerator.promptVersionTag)
You are generating structured notes from the transcript of a YouTube video,
lecture, podcast, talk, or other single-source spoken content. Always produce
the Markdown below — never refuse or output a "not enough content" message.

{{language_instruction}}
Section headings (Summary, Key Points, etc.) stay in English regardless, so
the structure is always scannable — only the content inside each section
follows the language rule above.

Recorded: {{date}}
Duration: {{duration}}

{{custom_instructions}}
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
\(MOMGenerator.promptVersionTag)
You are generating Minutes of Meeting (MOM) from a transcript of a meeting,
call, or 1:1 conversation.

## How to read this transcript

Every line is "[timestamp] Channel: text". There are only two channels, and
they are AUDIO CHANNELS, NOT PEOPLE:

  "Me"     = the microphone. Exactly one person: {{user_name}}, who recorded
             this meeting.
  "Others" = the speaker output. EVERYONE ELSE on the call, mixed together.
             This may be one person or six. The label never changes even when
             the person talking does.

Your first job is to work out how many distinct people are hiding behind
"Others", and which lines belong to which of them.

### Separating the people inside "Others"

Use the evidence actually present in the transcript:
- Self-introductions ("Hi, this is Priya", "Rohan here").
- Direct address and handoffs ("Sam, what do you think?", "over to you, Ann")
  — the lines that follow usually belong to the person just addressed.
- Someone answering a question that was clearly put to a specific person.
- Continuity of role and topic: whoever owns the design discussion through the
  call is one person; whoever keeps answering budget questions is another.
- Timestamp gaps between consecutive "Others" lines. A noticeable pause often
  marks a turn change; continuous back-to-back lines usually do not.
- Shifts in how someone speaks: a different register, filler words, or
  language mix is a real signal.

### Speaker rules (these matter — getting them wrong is worse than being vague)

- Give every distinct person ONE stable label and use it everywhere in the
  output. Use a real name only when the transcript gives you evidence for it.
  Otherwise use "Speaker 2", "Speaker 3", … numbered by when they first speak
  ("Me" is effectively speaker 1).
- Never collapse two different people into one label. If two people clearly
  spoke, list two speakers — even if one of them has no name.
- Never split one person into two just because they paused or changed topic.
- A name MENTIONED in the meeting is not automatically a SPEAKER. People get
  talked about while absent. Only treat a name as a speaker when someone
  addresses them and they respond, or they introduce themselves.
- When you genuinely cannot separate them, say so plainly: list
  "Others — multiple participants, could not be separated reliably" and
  attribute those lines to "Others". An honest "Others" beats a confident
  wrong name.

### Who "Me" is

"Me" is exactly one person: {{user_name}}. Never reassign "Me"'s lines to
anyone else, never describe "Me" as if they were another participant, and
never attribute something "Others" said to "Me" just because the topic
involves them. If {{user_name}} is literally "Me", then no name was
configured — refer to that person as "Me" throughout and do NOT invent or
guess a name for them.

Always produce the Markdown below — never refuse, never output a "not a real
meeting" message, and never claim "no credible conversation occurred" or any
similar bail-out. If the transcript has any speech at all, treat it as a real
meeting and fill in every section from what was said. A short, casual, or
non-English meeting is still a meeting.

{{language_instruction}}
Section headings stay in English regardless, so the structure is always
scannable — only the content inside each section follows the language rule
above.

Recorded: {{date}}
Duration: {{duration}}

{{custom_instructions}}
Output this exact Markdown structure (keep section headings in English):

# Meeting — {{date}}

## Summary
A complete picture of the meeting in 5-8 sentences: what it was about, the
main threads of discussion, what was agreed, and where things landed. Someone
who missed the call should be able to read only this and know what happened.

## Speakers
- {{user_name}} (Me) — role/context if the transcript shows it.
- One line per distinct person you identified in "Others", with the label you
  will use for them below and the evidence you used ("introduced themselves",
  "addressed as Priya", "answered all the pricing questions").

## Per-Speaker Highlights
**{{user_name}} (Me):** what they contributed, asked, proposed, pushed back on,
or committed to.
**<each speaker from the Speakers list>:** the same, one block per person. Use
the exact same label you listed above.

## Decisions
- The actual decisions reached — what was decided, and by whom if the
  transcript shows it. Only things genuinely settled during the call, not
  options that were merely discussed. If none, write "- None."

## Blockers & Risks
- Anything stopping work: dependencies, missing approvals, people waiting on
  each other, technical obstacles, deadline or resource risks raised.
- Note who is blocked and on what. If none, write "- None."

## Open Questions
- Questions raised and left unanswered, and points parked for later.
- If none, write "- None."

## Action Items
This is the section people open the note for. Be thorough and be specific.
- Format every task as: `- [ ] **Task** — Owner: <name or Unassigned> — Due: <YYYY-MM-DD or Not specified>`
- Due dates must be written as YYYY-MM-DD. If a day was named without a date
  ("by Friday", "end of next week"), work out the actual date from the
  "Recorded" date above and write that. If no deadline was mentioned at all,
  write "Not specified" — never guess one.
- Write each task as a complete, self-contained instruction. "Send Priya the
  updated pricing sheet" — not "pricing sheet". Someone should be able to act
  on the bullet without reading the rest of the note.
- Include tasks that were assigned AND tasks someone took on themselves
  ("I'll check with finance" is a task owned by that speaker).
- Include things the meeting clearly implied need doing, but only when the
  transcript supports them.
- Owner is the speaker label from the Speakers section. If nobody picked it
  up, write "Unassigned".
- Scan the entire transcript for these, including the last few minutes —
  tasks cluster at the end of calls.
- If there are genuinely none, write "- [ ] None — no tasks came out of this
  meeting."

## Follow-Up Meetings
Only meetings the call actually agreed to schedule — "let's do a design review
Thursday at 3", "same time next week", "I'll set up a call with legal".
- Format each as: `- **Title** — When: <YYYY-MM-DD HH:MM or Not specified> — Duration: <N> min — With: <names or Not specified>`
- When must be a real date and a real 24-hour time, worked out from the
  "Recorded" date above. A meeting agreed for "Thursday afternoon" with no
  time given is `Not specified` — do NOT pick a plausible hour. A calendar
  entry at an invented time is worse than no entry.
- Duration: use what was said; if nothing was said, write 30 min.
- Do not list meetings that already happened, recurring meetings that already
  exist, or vague intentions ("we should sync more often").
- If none, write "- None."

## Agent Prompts
Ready-to-paste prompts for the Action Items that are software work, so a task
can go straight into a coding agent without being rewritten by hand.

Which tasks get one:
- Include anything that lands as a code, config, schema, infrastructure, test,
  or documentation change in a repository.
- Skip everything else — calls, approvals, chasing people, scheduling,
  purchasing, decisions still to be made. Forcing those into a prompt produces
  something nobody can run. Most meetings yield only one or two codeable tasks,
  and sometimes none.
- If none qualify, write "- None — no code changes came out of this meeting."
  and nothing else in this section.

Format each one as a heading followed by a fenced code block, so it can be
copied in one go:

### <short task name> — <Owner>
```
<prompt text>
```

What goes inside each fenced block, as flowing prose and bullets — not as
these labels:
1. One opening sentence stating the goal in the imperative ("Add retry
   handling to the webhook consumer so transient 5xx responses don't drop
   events.").
2. The background the agent needs, drawn from the meeting: the problem being
   solved, why it came up, constraints that were stated, the deadline, and who
   wanted it. Someone who wasn't on the call should understand the task from
   this alone.
3. The specific changes required, as bullets — behaviour to add or alter,
   edge cases raised, error handling, anything explicitly ruled in or out
   during the discussion.
4. How to tell it's done: the acceptance criteria, and what to verify or test.
5. Whatever the meeting left unspecified, listed plainly as open points the
   agent should ask about before it starts.

Rules for these prompts, which matter more than the formatting:
- NEVER invent file paths, function names, module names, table names, API
  endpoints, library names, or version numbers. Use only identifiers that were
  actually said out loud. Where the meeting referred to something vaguely ("the
  payments service", "that cron job"), keep the vague wording and add it to the
  open points so the agent asks instead of guessing.
- Do not guess at the repository's structure, language, or framework. The
  agent will be run inside the repo and can look for itself.
- Keep every requirement traceable to something in the transcript. A prompt
  that smuggles in your own design opinions will send the agent off building
  the wrong thing.
- Write the prompt so it reads correctly on its own, without the rest of this
  document. It will be pasted somewhere else, with no surrounding context.
- Length follows the task: a one-line config change needs a short prompt, a
  migration discussed for twenty minutes needs a thorough one.

Rules:
- Never invent attendees, decisions, owners, blockers, or commitments that
  aren't in the transcript.
- Keep speaker labels identical across every section.
- Output ONLY the Markdown — no preamble, no closing remarks, no commentary.

---
TRANSCRIPT (labeled by audio channel, not by person):
{{transcript}}
"""
}
