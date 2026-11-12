import * as fs from "fs";
import * as path from "path";
import { documentsDir, ensureDir, HOME, isWin, nikxelPath, readText, writeAtomic } from "../core/paths";
import { run, RunResult, which } from "../core/proc";
import { CaptureMode, CodingAgent, Settings } from "../core/settings";
import { diag } from "../core/diag";
import { UsageLog } from "./usageLog";
import { NoteExporter } from "./noteExporter";
import { SummaryTemplates } from "./summaryTemplates";
import { meetingPrompt, notesPrompt } from "./momPrompts";

/// Port of MOMGenerator.swift.

// Per-agent CLI shape: where to find the binary, how to invoke it for a
// one-shot headless text-generation prompt, and how to pull plain text back
// out of whatever format that agent prints.
//
// On Windows all three get the prompt on stdin. A transcript is far past the
// 32 KB a Windows command line can carry (8 KB through cmd.exe, which npm's
// .cmd shims can end up going through), so the Mac's positional-argument
// shape for opencode and codex can't carry over.
interface AgentBackend {
  candidatePaths: () => string[];
  whichName: string;
  buildArgs: () => string[];
  parseOutput: (out: string) => string | null;
}

const appData = () => process.env.APPDATA ?? path.join(HOME, "AppData", "Roaming");

function backendFor(agent: CodingAgent): AgentBackend {
  switch (agent) {
    case "claude":
      return {
        candidatePaths: () => isWin
          ? [
            path.join(HOME, ".local", "bin", "claude.exe"),       // native installer
            path.join(appData(), "npm", "claude.cmd"),            // npm install -g
            path.join(HOME, ".claude", "local", "claude.cmd"),
          ]
          : ["/opt/homebrew/bin/claude", path.join(HOME, ".claude/local/claude"), path.join(HOME, ".local/bin/claude"), "/usr/local/bin/claude"],
        whichName: "claude",
        // -p is headless one-shot and reads the prompt from stdin. Empty
        // --allowed-tools keeps it pure text generation: these prompts need no
        // file or shell access, and a tool call that stops for a permission
        // prompt would hang a GUI-spawned process with nobody to answer it.
        //
        // The rest strips the user's own hooks, plugins, MCP servers and
        // skills from these runs: they added ~28k tokens to every call
        // (a one-line WhatsApp reply cost $0.12) and nothing here uses
        // them. No session persistence, or these runs show up in
        // ~/.claude/projects as if the user had typed them. JSON output
        // carries the token count and cost (UsageLog).
        buildArgs: () => ["-p", "--allowed-tools", "",
          "--setting-sources", "", "--strict-mcp-config",
          "--disable-slash-commands", "--no-session-persistence",
          "--output-format", "json"],
        parseOutput: out => {
          let obj: any;
          try { obj = JSON.parse(out); } catch { return out; }
          if (!obj || typeof obj !== "object" || Array.isArray(obj)) return out;
          return typeof obj.result === "string" ? obj.result : null;
        },
      };
    case "opencode":
      return {
        candidatePaths: () => isWin
          ? [path.join(HOME, ".opencode", "bin", "opencode.exe"), path.join(appData(), "npm", "opencode.cmd")]
          : [path.join(HOME, ".opencode/bin/opencode"), "/opt/homebrew/bin/opencode", path.join(HOME, ".local/bin/opencode"), "/usr/local/bin/opencode"],
        whichName: "opencode",
        // `opencode run` with no message reads it from stdin (when stdin is
        // not a terminal, which it never is here). --format json gives
        // newline-delimited event objects instead of the human-readable
        // banner + reply that the default format prints (which would pollute
        // the saved .md).
        buildArgs: () => ["run", "--format", "json"],
        parseOutput: parseOpenCodeNDJSON,
      };
    case "codex":
      return {
        candidatePaths: () => isWin
          ? [path.join(appData(), "npm", "codex.cmd"), path.join(HOME, ".local", "bin", "codex.exe")]
          : ["/opt/homebrew/bin/codex", path.join(HOME, ".local/bin/codex"), "/usr/local/bin/codex"],
        whichName: "codex",
        // `codex exec -` reads the prompt from stdin. UNVERIFIED on Windows,
        // as the exact flags/output were on the Mac (no working codex binary
        // to test against); confirm once one is available.
        //
        // Runs in ~/.nikxel/momworkspace, which is no git repo; without
        // --skip-git-repo-check codex refuses with "Not inside a trusted
        // directory". Found by the setup wizard's agent test.
        buildArgs: () => ["exec", "--skip-git-repo-check", "-"],
        parseOutput: out => out,
      };
  }
}

// opencode's --format json prints one JSON object per line; the reply
// text is spread across one or more {"type":"text",...} events.
function parseOpenCodeNDJSON(text: string): string | null {
  let out = "";
  for (const line of text.split("\n")) {
    if (!line.trim()) continue;
    try {
      const obj = JSON.parse(line);
      if (obj?.type === "text" && typeof obj.part?.text === "string") out += obj.part.text;
    } catch { /* not an event line */ }
  }
  return out === "" ? null : out;
}

/// Plain text, not a wrapped object: the failure card splits the message on
/// real newlines to find the reason and the "Logs:" path.
export class MOMError extends Error {
  constructor(readonly kind: "agentNotFound" | "transcriptEmpty" | "generationFailed", message?: string) {
    super(message ?? (kind === "agentNotFound" ? "No coding agent found."
      : kind === "transcriptEmpty" ? "The transcript was empty." : "Generation failed."));
    this.name = "MOMError";
  }
}

/// A summary that was started but never written.
export interface PendingJob {
  /// The file stem shared by the transcript, the note and the marker.
  id: string;
  mode: CaptureMode;
  startedAt: Date;
  durationSec: number;
  transcriptPath: string;
}

/// Outcome of `checkAgent`, in the order a person would fix things: install
/// it, sign in, then whatever else is wrong. `reason` is the wizard's text.
export type AgentHealth = { working: true; detail?: string } | { working: false; notInstalled: boolean; reason: string };

const pad = (n: number) => String(n).padStart(2, "0");

// Seconds in the stem so two recordings started in the same minute don't
// overwrite each other's files. Same names as the Mac build (no colons).
export function timestampStem(d: Date): string {
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}-${pad(d.getHours())}${pad(d.getMinutes())}${pad(d.getSeconds())}`;
}

function promptDate(d: Date): string {
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())} ${pad(d.getHours())}:${pad(d.getMinutes())}`;
}

export class MOMGenerator {
  // Upper bound on a single agent run. Generation normally takes well under
  // a minute; anything past this is a hang, not slow work.
  static readonly timeoutSec = 600;

  /// Bumped whenever the shipped prompts change in a way existing installs
  /// need. Every default prompt carries it as `promptVersionTag`, so an
  /// out-of-date copy in ~/.nikxel/prompts/ is replaced on next launch.
  static readonly promptVersion = 6;
  private static readonly versionTagPrefix = "<!-- nikxel-prompt v";
  static get promptVersionTag(): string { return `${MOMGenerator.versionTagPrefix}${MOMGenerator.promptVersion} -->`; }

  /// The version stamped into an on-disk prompt, or null if it predates
  /// versioning (or the user removed the tag, which opts them out).
  static stampedVersion(text: string): number | null {
    const at = text.indexOf(MOMGenerator.versionTagPrefix);
    if (at < 0) return null;
    const from = at + MOMGenerator.versionTagPrefix.length;
    const end = text.indexOf(" -->", from);
    if (end < 0) return null;
    const raw = text.slice(from, end);
    return /^[+-]?\d+$/.test(raw) ? Number(raw) : null;
  }

  private readonly promptsDir = ensureDir(nikxelPath("prompts"));
  private readonly workspace = ensureDir(nikxelPath("momworkspace"));
  private get notesDir(): string { return documentsDir("notes"); }
  private get meetingsDir(): string { return documentsDir("meetings"); }

  constructor() {
    this.seedDefaultPrompts();
  }

  /// Resolves to the note's path (the .md, or the PDF/Word file rendered from it).
  async generate(transcript: string, mode: CaptureMode, startedAt: Date, durationSec: number): Promise<string> {
    const trimmed = transcript.trim();
    if (trimmed.split(/\s+/).filter(Boolean).length < 3) throw new MOMError("transcriptEmpty");

    // Save the raw transcript before attempting generation, so an agent
    // failure/timeout/missing-binary still leaves the full transcript on
    // disk instead of losing it with the recording.
    let transcriptPath: string | null = null;
    try { transcriptPath = this.saveTranscript(trimmed, mode, startedAt); }
    catch (e) { diag("MOM", `couldn't save transcript: ${e}`); }

    // Record that a summary is owed for this transcript. Deleted on
    // success; anything left behind is an unfinished job that
    // "Regenerate Unfinished Summary" can pick up later -- including
    // after a crash or a quit mid-generation.
    const stem = timestampStem(startedAt);
    this.writeMarker(stem, mode, startedAt, durationSec, transcriptPath);

    const agent = Settings.connectedAgent;
    const bin = this.findBinary(agent);
    if (!bin) throw new MOMError("agentNotFound");
    const runDir = path.join(this.workspace, stem);
    const output = await this.runTemplate(bin, agent, mode, trimmed, startedAt, durationSec, runDir);
    const outPath = await this.saveOutput(output, mode, startedAt);
    this.clearMarker(stem);
    return outPath;
  }

  // Resolves the installed binary for `agent`: common install locations
  // first, then PATH plus the folders a terminal would have (npm's global
  // bin, ~/.local/bin, scoop) -- same approach for every agent.
  findBinary(agent: CodingAgent): string | null {
    const backend = backendFor(agent);
    return which(backend.whichName, backend.candidatePaths());
  }

  /// Tests `agent` end to end: the binary exists, it starts (`--version` --
  /// catches installs whose native package is missing), and a real one-word
  /// prompt comes back. The last step is the only honest "logged in" test:
  /// none of the CLIs share an auth-status command, and a stale token looks
  /// fine until a request is made.
  async checkAgent(agent: CodingAgent): Promise<AgentHealth> {
    const bin = this.findBinary(agent);
    if (!bin) return { working: false, notInstalled: true, reason: "Not installed" };
    const version = await run(bin, ["--version"], { timeoutMs: 15_000 });
    const vOut = version.stdout.trim(), vErr = version.stderr.trim();
    if (version.code !== 0) {
      const why = version.timedOut ? "timed out"
        : [vErr, vOut].find(s => s !== "") ?? version.error?.message ?? `exited with code ${version.code}`;
      return { working: false, notInstalled: false, reason: `Installed but won't start: ${why.slice(0, 200)}` };
    }
    const versionLine = vOut.split("\n")[0]?.trim() ?? "";
    const dir = path.join(this.workspace, `healthcheck-${agent}`);
    try {
      const reply = await this.executeAgent(bin, agent, "Reply with the single word OK and nothing else.",
        { runDir: dir, kind: "healthcheck", timeoutSec: 60 });
      return reply.trim() === ""
        ? { working: false, notInstalled: false, reason: "Installed, but a test request failed: empty reply" }
        : { working: true, detail: versionLine };
    } catch (e) {
      const full = e instanceof Error ? e.message : String(e);
      const msg = full.split("\n\nLogs:")[0];
      const lower = msg.toLowerCase();
      const authHints = ["not logged in", "log in", "login", "/login", "unauthorized", "authenticate",
        "api key", "401", "sign in", "credentials", "invalid x-api-key"];
      return authHints.some(h => lower.includes(h))
        ? { working: false, notInstalled: false, reason: "Installed, but not logged in" }
        : { working: false, notInstalled: false, reason: `Installed, but a test request failed: ${msg.slice(0, 200)}` };
    }
  }

  private promptPath(mode: CaptureMode): string {
    return path.join(this.promptsDir, mode === "notes" ? "notes.md" : "meeting.md");
  }

  private runTemplate(binary: string, agent: CodingAgent, mode: CaptureMode, transcript: string,
    startedAt: Date, durationSec: number, runDir: string): Promise<string> {
    const template = readText(this.promptPath(mode)) ?? this.defaultPrompt(mode);
    // split/join rather than replace(): a transcript containing "$&" must
    // not be read as a replacement pattern.
    const sub = (s: string, key: string, value: string) => s.split(key).join(value);
    let prompt = template;
    prompt = sub(prompt, "{{date}}", promptDate(startedAt));
    prompt = sub(prompt, "{{duration}}", `${Math.trunc(durationSec / 60)} min ${durationSec % 60} sec`);
    prompt = sub(prompt, "{{transcript}}", transcript);
    prompt = sub(prompt, "{{language_instruction}}", Settings.languageInstruction);
    prompt = sub(prompt, "{{user_name}}", Settings.userName);
    prompt = sub(prompt, "{{custom_instructions}}", SummaryTemplates.summaryStyleInstruction);
    return this.executeAgent(binary, agent, prompt, { runDir, kind: mode });
  }

  // Run an arbitrary prompt through the agent. Used by DayLogger for EOD
  // summaries and by LLMResponder for chat replies.
  /// `kind` labels the run in UsageLog. `claudeModel` overrides the model
  /// when the agent is Claude Code; other agents ignore it.
  async runPrompt(prompt: string, kind: string, claudeModel?: string): Promise<string> {
    const agent = Settings.connectedAgent;
    const bin = this.findBinary(agent);
    if (!bin) throw new MOMError("agentNotFound");
    return this.executeAgent(bin, agent, prompt, { kind, claudeModel });
  }

  private async executeAgent(binary: string, agent: CodingAgent, prompt: string,
    opts: { runDir?: string; kind: string; claudeModel?: string; timeoutSec?: number }): Promise<string> {
    const timeout = opts.timeoutSec ?? MOMGenerator.timeoutSec;
    // Each run gets its own directory. These used to be fixed names in one
    // shared folder, so two overlapping runs -- easy to trigger by starting
    // a second recording while the first was still summarizing -- wiped
    // each other's logs, leaving nothing to diagnose a failure with.
    const workspace = ensureDir(opts.runDir ?? this.workspace);
    const backend = backendFor(agent);
    const promptDump = path.join(workspace, "last_prompt.txt");
    const stdoutDump = path.join(workspace, "last_stdout.log");
    const stderrDump = path.join(workspace, "last_stderr.log");
    await fs.promises.writeFile(promptDump, prompt, "utf8").catch(() => {});

    const args = [...backend.buildArgs(), ...(agent === "claude" && opts.claudeModel ? ["--model", opts.claudeModel] : [])];

    // Without a timeout the pet sits in writingMOM forever whenever the agent
    // hangs (opencode used to retry a failing stream with backoff and never
    // exit), so no alert ever fires and the animation never stops.
    // ponytail: fixed ceiling; make it a setting if a long transcript ever
    // legitimately runs past it.
    //
    // run() kills the process tree at the timeout, but its promise waits for
    // the pipes to close, and a lingering grandchild can hold them open past
    // the kill. The bounded race keeps that from reintroducing the stall.
    let outSoFar = "", errSoFar = "";
    let hard: NodeJS.Timeout | undefined;
    const r: RunResult = await Promise.race([
      run(binary, args, {
        cwd: workspace,
        input: prompt,
        timeoutMs: timeout * 1000,
        onStdout: d => { outSoFar += d; },
        onStderr: d => { errSoFar += d; },
      }),
      new Promise<RunResult>(resolve => {
        hard = setTimeout(() => resolve({ code: null, stdout: outSoFar, stderr: errSoFar, timedOut: true }), timeout * 1000 + 15_000);
      }),
    ]);
    if (hard) clearTimeout(hard);
    await fs.promises.writeFile(stdoutDump, r.stdout).catch(() => {});
    await fs.promises.writeFile(stderrDump, r.stderr).catch(() => {});

    if (r.timedOut) {
      const limit = timeout >= 60 ? `${Math.trunc(timeout / 60)} min` : `${Math.trunc(timeout)} s`;
      throw new MOMError("generationFailed",
        `${backend.whichName} did not finish within ${limit} and was killed.\nCheck that \`${backend.whichName}\` works in a terminal (login / quota).\n${r.stderr.slice(-300)}\n\nLogs: ${workspace}`);
    }

    if (r.error) {
      throw new MOMError("generationFailed", `${backend.whichName} couldn't start: ${r.error.message}\n\nLogs: ${workspace}`);
    }

    if (r.code !== 0) {
      // claude --output-format json reports its failures ("Not logged
      // in", "Credit balance is too low") in stdout's `result`, with
      // stderr empty -- which used to surface as just "exit 1".
      let errStr = r.stderr.trim();
      if (!errStr) {
        let result: unknown;
        try { result = JSON.parse(r.stdout)?.result; } catch { /* not JSON */ }
        errStr = (typeof result === "string" ? result : r.stdout.slice(-500)).trim();
      }
      const snippet = errStr ? errStr.slice(0, 500) : `${backend.whichName} exited with code ${r.code}`;
      throw new MOMError("generationFailed", `${snippet}\n\nLogs: ${workspace}`);
    }
    if (agent === "claude") UsageLog.record(opts.kind, r.stdout);
    const out = backend.parseOutput(r.stdout);
    if (out === null) throw new MOMError("generationFailed", `non-utf8 or unparseable output\n\nLogs: ${workspace}`);
    if (out.trim() === "") {
      throw new MOMError("generationFailed", `empty output from ${backend.whichName}\n${r.stderr.slice(0, 300)}\n\nLogs: ${workspace}`);
    }
    return out;
  }

  private async saveOutput(content: string, mode: CaptureMode, startedAt: Date): Promise<string> {
    const dir = mode === "notes" ? this.notesDir : this.meetingsDir;
    const file = path.join(dir, `${timestampStem(startedAt)}.md`);
    writeAtomic(file, content);

    // Always keep the Markdown -- it's what the agent produced and what the
    // other formats render from. A failed conversion shouldn't lose the
    // note, so fall back to handing back the .md.
    const format = Settings.noteFormat;
    if (format === "markdown") return file;
    try {
      return await NoteExporter.export(content, file, format);
    } catch (e) {
      diag("MOM", `note export to ${format} failed: ${e}`);
      return file;
    }
  }

  // Written before generation runs, so the full transcript survives even if
  // the agent is missing, times out, or returns an error. Shares its filename
  // stem with saveOutput's .md so the two are easy to pair up by eye.
  private saveTranscript(content: string, mode: CaptureMode, startedAt: Date): string {
    const dir = mode === "notes" ? this.notesDir : this.meetingsDir;
    const file = path.join(dir, `${timestampStem(startedAt)}.transcript.txt`);
    writeAtomic(file, content);
    return file;
  }

  // MARK: - Unfinished jobs

  private get pendingDir(): string { return ensureDir(nikxelPath("pending")); }

  private writeMarker(stem: string, mode: CaptureMode, startedAt: Date, durationSec: number, transcript: string | null): void {
    if (!transcript) return;
    const payload = { mode, startedAt: startedAt.getTime() / 1000, durationSec, transcript };
    try { fs.writeFileSync(path.join(this.pendingDir, `${stem}.json`), JSON.stringify(payload)); } catch { /* best effort */ }
  }

  private clearMarker(stem: string): void {
    try { fs.rmSync(path.join(this.pendingDir, `${stem}.json`), { force: true }); } catch { /* ignore */ }
  }

  /// Summaries that were started but never finished, newest first. A marker
  /// whose transcript has since vanished is dropped rather than reported.
  unfinishedJobs(): PendingJob[] {
    const dir = this.pendingDir;
    let names: string[];
    try { names = fs.readdirSync(dir); } catch { return []; }
    const jobs: PendingJob[] = [];
    for (const name of names) {
      if (!name.endsWith(".json")) continue;
      const file = path.join(dir, name);
      let obj: any;
      try { obj = JSON.parse(fs.readFileSync(file, "utf8")); } catch { continue; }
      if (typeof obj?.mode !== "string" || typeof obj.startedAt !== "number"
        || !Number.isInteger(obj.durationSec) || typeof obj.transcript !== "string") continue;
      try { fs.accessSync(obj.transcript, fs.constants.R_OK); }
      catch { try { fs.rmSync(file, { force: true }); } catch { /* ignore */ } continue; }
      jobs.push({
        id: name.slice(0, -5),
        mode: obj.mode === "notes" ? "notes" : "meeting",
        startedAt: new Date(obj.startedAt * 1000),
        durationSec: obj.durationSec,
        transcriptPath: obj.transcript,
      });
    }
    return jobs.sort((a, b) => b.startedAt.getTime() - a.startedAt.getTime());
  }

  /// Re-runs generation from a saved transcript.
  async regenerate(job: PendingJob): Promise<string> {
    let transcript: string;
    try { transcript = await fs.promises.readFile(job.transcriptPath, "utf8"); }
    catch { throw new MOMError("transcriptEmpty"); }
    return this.generate(transcript, job.mode, job.startedAt, job.durationSec);
  }

  // MARK: - Prompts

  private seedDefaultPrompts(): void {
    for (const mode of ["notes", "meeting"] as CaptureMode[]) {
      const file = this.promptPath(mode);
      const fresh = this.defaultPrompt(mode);
      const existing = readText(file);
      const write = () => { try { writeAtomic(file, fresh); } catch { /* read-only home */ } };
      if (existing === null) { write(); continue; }
      const stamped = MOMGenerator.stampedVersion(existing);
      if (stamped !== null) {
        // Versioned copy: replace only when it is behind. A user who
        // edited the prompt but kept the tag still gets updates; one
        // who deleted the tag is treated as having customized it.
        if (stamped < MOMGenerator.promptVersion) write();
        continue;
      }
      // Pre-versioning copies, identified by phrases unique to the
      // defaults that shipped before the tag existed. The first three
      // told the model to write in the transcript's language, which
      // produced Hindi notes and false "no credible conversation"
      // bail-outs; the last is the MOM prompt that collapsed every
      // remote participant into a single "Others".
      const legacyMarkers = [
        "Write the notes in the SAME language as the transcript",
        "Write the MOM in the SAME language as the transcript",
        "translate the section headings to match",
        "ALWAYS write the notes in English regardless of the transcript",
        "ALWAYS write the MOM in English regardless of the transcript",
        "IMPORTANT identity rule:",
        "## How to read this transcript",
      ];
      if (legacyMarkers.some(m => existing.includes(m))) write();
    }
  }

  private defaultPrompt(mode: CaptureMode): string {
    return mode === "notes" ? notesPrompt(MOMGenerator.promptVersionTag) : meetingPrompt(MOMGenerator.promptVersionTag);
  }
}
