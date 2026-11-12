import * as fs from "fs";
import * as path from "path";
import { Notification } from "electron";
import { StateMachine } from "../core/stateMachine";
import { CaptureMode, Settings } from "../core/settings";
import { ui } from "../core/ui";
import { bus } from "../core/bus";
import { diag } from "../core/diag";
import { openFile, openUrl } from "../core/open";
import { AudioRecorder, AudioRecorderDelegate, RecorderError, RecordingArtifacts } from "./audioRecorder";
import { Transcriber, TranscriberError } from "./transcriber";
import { TranscriptMerger } from "./transcriptMerger";
import { MOMGenerator } from "./momGenerator";
import { GoogleSync } from "../google/googleSync";

/// Port of MeetingCoordinator.swift.

export class MeetingCoordinator implements AudioRecorderDelegate {
  readonly recorder = new AudioRecorder();
  readonly transcriber = new Transcriber();
  readonly momGen = new MOMGenerator();

  /// Set while a recording is being transcribed/summarized. A double-click on
  /// the avatar used to start a fresh recording here, which buried the work in
  /// progress: the writingMOM animation got clobbered by recording, the new
  /// (near-empty) recording raised its own "generation failed" alert, and the
  /// two runs overwrote each other's logs.
  private _isProcessing = false;
  get isProcessing(): boolean { return this._isProcessing; }

  get isRecording(): boolean { return this.recorder.isRecording; }

  /// Between a toggle and the recorder confirming it.
  private switching = false;

  /// Shown notifications, held so they aren't garbage-collected before the
  /// user clicks them (Electron drops the click handler with the object).
  private notifications = new Set<Notification>();

  constructor(readonly stateMachine: StateMachine) {
    this.recorder.delegate = this;
  }

  /// `force` comes from the tray menu, which stays unguarded as the deliberate
  /// way to record while a summary is still being written. The avatar's
  /// double-click does not, because that is the accidental path.
  ///
  /// Starting takes a moment (capture spin-up) and stopping as long
  /// (teardown + closing the files), so the avatar switches at once and
  /// further toggles are ignored until the recorder catches up -- otherwise
  /// the double-click meant to stop it landed in that gap and started a
  /// second recording.
  toggleRecording(force = false): void {
    if (this.switching) return;
    if (this.recorder.isRecording) {
      this.switching = true;
      this.stateMachine.stopRecording();
      ui.setRecordingStartedAt(null);
      this.recorder.stop();
      bus.emit("menuChanged");
      return;
    }
    if (this._isProcessing && !force) {
      ui.pushReminder("nikxel.busy", "Still writing your notes…");
      return;
    }
    this.switching = true;
    this.stateMachine.startRecording();
    ui.setRecordingStartedAt(Date.now());
    this.recorder.captureMode = Settings.captureMode;
    this.recorder.start();
  }

  recorderDidStart(): void {
    this.switching = false;
    this.stateMachine.startRecording();
    ui.setRecordingStartedAt(Date.now());
    bus.emit("menuChanged");
  }

  recorderMicUnavailable(reason: string, blocked: boolean): void {
    ui.showCard({
      icon: "🎙️",
      title: "Recording without your microphone",
      lines: blocked
        ? [reason, "Tap to allow microphone access for desktop apps in Settings. Your next recording will pick it up."]
        : [reason, "Recording system audio only."],
      kind: "warning",
      lifetime: blocked ? Infinity : 20,
      action: blocked ? () => openUrl("ms-settings:privacy-microphone") : undefined,
    });
  }

  recorderDidStop(artifacts: RecordingArtifacts | null, error: Error | null): void {
    this.switching = false;
    this.stateMachine.stopRecording();
    ui.setRecordingStartedAt(null);
    bus.emit("menuChanged");

    if (error) {
      this.showRecordErrorCard(error);
      return;
    }

    if (!artifacts) {
      this._isProcessing = false;
      this.notify("Recording failed", "No audio file produced.");
      return;
    }

    const startedAt = this.recorder.startedAt ?? new Date();
    const durationSec = Math.max(1, Math.trunc((Date.now() - startedAt.getTime()) / 1000));

    this._isProcessing = true;
    this.stateMachine.startWritingMOM();
    if (artifacts.kind === "merged") {
      void this.runNotesPipeline(artifacts.path, startedAt, durationSec);
    } else {
      void this.runMeetingPipeline(artifacts.mic, artifacts.sys, startedAt, durationSec);
    }
  }

  /// The Mac pointed at the Screen Recording grant here. Windows needs no
  /// grant for loopback audio, so the likely causes are no output device or
  /// the capture being refused; point at the matching Settings page.
  private showRecordErrorCard(error: Error): void {
    const name = error instanceof RecorderError ? error.errorName : error.name;
    const refused = name === "NotAllowedError" || name === "SecurityError";
    const page = refused ? "ms-settings:privacy" : "ms-settings:sound";
    const hint = refused
      ? "Windows refused to share the computer's audio. Tap to check privacy settings, then try again."
      : "Tap to check your sound output device in Settings, then try again.";
    ui.showCard({
      icon: "⚠️",
      title: "Couldn't record",
      lines: [error.message.slice(0, 160), hint],
      kind: "error",
      lifetime: Infinity,
      action: () => openUrl(page),
    });
  }

  // MARK: - Notes pipeline

  private async runNotesPipeline(audioPath: string, startedAt: Date, durationSec: number): Promise<void> {
    let text: string;
    try {
      const txtPath = await this.transcriber.transcribe(audioPath, "txt");
      try { text = await fs.promises.readFile(txtPath, "utf8"); }
      catch { throw new TranscriberError("failed", `could not read transcript at ${txtPath}`); }
    } catch (e) {
      this.reportTranscribeFailure(e);
      return;
    }
    await this.generate(text, "notes", startedAt, durationSec, () => {
      fs.promises.rm(audioPath, { force: true }).catch(() => {});
    });
  }

  // MARK: - Meeting pipeline

  private async runMeetingPipeline(micPath: string | null, sysPath: string, startedAt: Date, durationSec: number): Promise<void> {
    // Both tracks transcribe at once; one failing still leaves the other.
    const [sys, mic] = await Promise.allSettled([
      this.transcriber.transcribe(sysPath, "srt"),
      micPath ? this.transcriber.transcribe(micPath, "srt") : Promise.resolve(null),
    ]);
    const sysSRT = sys.status === "fulfilled" ? sys.value : null;
    const micSRT = mic.status === "fulfilled" ? mic.value : null;
    const firstError = sys.status === "rejected" ? sys.reason : mic.status === "rejected" ? mic.reason : null;
    if (firstError && !sysSRT && !micSRT) {
      this.reportTranscribeFailure(firstError);
      return;
    }
    const merged = TranscriptMerger.merge(micSRT, sysSRT);
    await this.generate(merged, "meeting", startedAt, durationSec, () => {
      if (micPath) fs.promises.rm(micPath, { force: true }).catch(() => {});
      fs.promises.rm(sysPath, { force: true }).catch(() => {});
    });
  }

  // MARK: - Shared generate step

  private async generate(transcript: string, mode: CaptureMode, startedAt: Date, durationSec: number, cleanup: () => void): Promise<void> {
    let outPath: string;
    try {
      outPath = await this.momGen.generate(transcript, mode, startedAt, durationSec);
    } catch (err) {
      this._isProcessing = false;
      this.stateMachine.endWritingMOM();
      // A card rather than a modal: a failure here costs nothing -- the
      // transcript was written before generation ran and "Regenerate
      // Unfinished Summary" picks it back up -- so stealing focus mid-work
      // is the wrong trade. It stays put until clicked, and clicking opens
      // the run's logs.
      this.showFailureCard(
        mode === "notes" ? "Couldn't write your notes" : "Couldn't write the minutes",
        err,
        "Your transcript is saved — tray menu → Regenerate Unfinished Summary.");
      return;
    }
    this._isProcessing = false;
    // endWritingMOM first: writingMOM is sticky in setState, so
    // triggerMomReady would be swallowed while it's held.
    this.stateMachine.endWritingMOM();
    this.stateMachine.triggerMomReady();
    this.notify(mode === "notes" ? "Notes ready" : "MOM ready", path.basename(outPath), outPath);
    this.showReadyCard(mode, outPath);
    cleanup();
    // Meetings only -- a lecture or podcast has no owners and nothing to put
    // in anyone's calendar. No-ops unless the user has connected Google, and
    // always asks first.
    if (mode === "meeting") {
      GoogleSync.offer(outPath).catch(e => diag("MeetingCoordinator", `GoogleSync.offer failed: ${e}`));
    }
  }

  private reportTranscribeFailure(err: unknown): void {
    this._isProcessing = false;
    this.stateMachine.endWritingMOM();
    this.showFailureCard("Couldn't transcribe the recording", err,
      "Check that whisper is installed — Setup → Transcription tools.");
  }

  // MARK: - Cards

  /// "MOM ready" with the note's own action items as bullets -- the first
  /// thing anyone opens the note for, so it goes straight on the card.
  /// Reuses GoogleSync's parser rather than a second one.
  private showReadyCard(mode: CaptureMode, outPath: string): void {
    const mdPath = path.extname(outPath).toLowerCase() === ".md"
      ? outPath
      : path.join(path.dirname(outPath), `${path.basename(outPath, path.extname(outPath))}.md`);
    let md = "";
    try { md = fs.readFileSync(mdPath, "utf8"); } catch { /* card falls back below */ }

    let lines: string[];
    if (mode === "meeting") {
      lines = GoogleSync.parseActionItems(md).slice(0, 3).map(a => a.title);
      if (lines.length === 0) lines = ["No tasks came out of this one."];
    } else {
      lines = MeetingCoordinator.firstBullets(GoogleSync.section(md, "Key Points"), 3);
      if (lines.length === 0) lines = [path.basename(mdPath)];
    }

    ui.showCard({
      icon: "📄",
      title: mode === "notes" ? "Notes ready" : "Minutes ready",
      lines,
      bulleted: true,
      kind: "success",
      lifetime: 25,
      action: () => { void openFile(outPath); },
    });
  }

  private showFailureCard(title: string, error: unknown, hint: string): void {
    // Agent errors carry a "Logs: <path>" tail; pull it out so tapping the
    // card lands somewhere useful, and keep it out of the visible text.
    const full = error instanceof Error ? error.message : String(error);
    let logPath: string | null = null;
    const at = full.indexOf("Logs: ");
    if (at >= 0) logPath = full.slice(at + 6).split(/\r?\n/)[0].trim() || null;
    const reason = full.split("\n").map(l => l.trim()).find(l => l !== "" && !l.startsWith("Logs: ")) ?? "Unknown error.";
    diag("MeetingCoordinator", `${title}: ${full}`);

    ui.showCard({
      icon: "⚠️",
      title,
      lines: [reason.slice(0, 160), hint],
      kind: "error",
      lifetime: Infinity,   // stays until clicked
      action: () => { if (logPath) void openFile(logPath); },
    });
  }

  /// Leading "- " / "* " bullets from a Markdown section, trimmed of inline
  /// markers, for the notes card.
  static firstBullets(section: string, limit: number): string[] {
    const out: string[] = [];
    for (const raw of section.split(/\r?\n/)) {
      const line = raw.trim();
      if (!line.startsWith("- ") && !line.startsWith("* ")) continue;
      const text = line.slice(2).replace(/\*\*/g, "").replace(/`/g, "").trim();
      if (!text || text.toLowerCase() === "none." || text.toLowerCase() === "none") continue;
      out.push(text);
      if (out.length === limit) break;
    }
    return out;
  }

  // MARK: - Notifications

  /// Windows toast. Clicking it opens the note, as the Mac's did.
  private notify(title: string, body: string, openOnTap?: string): void {
    if (!Notification.isSupported()) return;
    const n = new Notification({ title, body });
    this.notifications.add(n);
    const release = () => { this.notifications.delete(n); };
    n.on("click", () => { if (openOnTap) void openFile(openOnTap); release(); });
    n.on("close", release);
    n.on("failed", release);
    // Toasts go to Action Center and can be clicked hours later; let go eventually.
    setTimeout(release, 6 * 60 * 60 * 1000).unref?.();
    n.show();
  }
}
