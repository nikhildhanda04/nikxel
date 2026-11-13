import * as fs from "fs";
import * as path from "path";
import { BrowserWindow, desktopCapturer, ipcMain, IpcMainEvent, session, Session, systemPreferences } from "electron";
import { ensureDir, isWin, nikxelPath, preloadPath, rendererPath } from "../core/paths";
import { CaptureMode, Settings } from "../core/settings";
import { diag } from "../core/diag";
import { WavWriter } from "./wavWriter";

/// Port of AudioRecorder.swift + MicRecorder.swift.
///
/// The capture itself runs in a hidden renderer (renderer/recorder.ts):
/// Chromium's getDisplayMedia with WASAPI loopback is Windows' ScreenCaptureKit
/// audio, and getUserMedia its AVAudioEngine. This side owns the window, the
/// permission plumbing and the WAV files the renderer streams into.

export type RecordingArtifacts =
  | { kind: "merged"; path: string }
  | { kind: "split"; mic: string | null; sys: string };

export interface AudioRecorderDelegate {
  recorderDidStart(): void;
  recorderDidStop(artifacts: RecordingArtifacts | null, error: Error | null): void;
  /// The mic couldn't start; recording carries on with system audio only.
  /// `blocked` is Windows microphone privacy saying no.
  recorderMicUnavailable?(reason: string, blocked: boolean): void;
}

/// A failed start. `stage` is where: "system" (loopback capture), "audio"
/// (the Web Audio graph), "window" (the recorder page) or "timeout".
export class RecorderError extends Error {
  constructor(message: string, readonly stage: string, readonly errorName: string) {
    super(message);
    this.name = "RecorderError";
  }
}

type Track = "mix" | "mic" | "sys";
const TRACKS: Track[] = ["mix", "mic", "sys"];
const PARTITION = "nikxel-recorder";
const SAMPLE_RATE = 16000;

const pad = (n: number) => String(n).padStart(2, "0");
/// Seconds in the stem so back-to-back recordings within the same minute
/// don't collide on the WAV paths or the per-track sys/mic files.
function recordingStem(d: Date): string {
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}-${pad(d.getHours())}${pad(d.getMinutes())}${pad(d.getSeconds())}`;
}

let sessionConfigured = false;

/// The recorder's own session, so its media grants don't depend on whatever
/// handlers other windows install on the default one.
function recorderSession(): Session {
  const ses = session.fromPartition(PARTITION);
  if (sessionConfigured) return ses;
  sessionConfigured = true;
  const allowed = (p: string) => p === "media" || p === "display-capture";
  ses.setPermissionRequestHandler((_wc, permission, cb) => cb(allowed(permission)));
  ses.setPermissionCheckHandler((_wc, permission) => allowed(permission));
  // getDisplayMedia: the first screen (required to get a stream at all; the
  // page drops the video track at once) plus system audio via WASAPI loopback.
  ses.setDisplayMediaRequestHandler((_request, callback) => {
    desktopCapturer.getSources({ types: ["screen"], thumbnailSize: { width: 0, height: 0 } })
      .then(sources => {
        if (!sources[0]) { diag("Recorder", "no screen source for loopback capture"); callback(null); return; }
        callback({ video: sources[0], audio: "loopback" });
      })
      .catch(e => { diag("Recorder", `desktopCapturer failed: ${e}`); callback(null); });
  });
  return ses;
}

type StartReply = { ok: true } | { ok: false; error: Error };

export class AudioRecorder {
  delegate: AudioRecorderDelegate | null = null;

  /// Set by the coordinator before start(). Captured at start time; mid-recording
  /// menu toggles do not affect an in-flight session.
  captureMode: CaptureMode = "notes";
  private activeMode: CaptureMode = "notes";

  private _isRecording = false;
  get isRecording(): boolean { return this._isRecording; }
  startedAt: Date | null = null;

  /// Tracks the in-flight stop teardown. The next start() awaits this before
  /// beginning so the two don't race on the window and the WAV writers.
  private teardown: Promise<void> | null = null;
  private starting = false;

  private win: BrowserWindow | null = null;
  private loaded: Promise<void> | null = null;
  private paths: Record<Track, string> | null = null;
  private writers = new Map<Track, WavWriter>();
  /// Chunks are only written between a start request and finalize().
  private capturing = false;
  private pendingStart: ((r: StartReply) => void) | null = null;
  private pendingStop: (() => void) | null = null;

  private muted = Settings.micMuted;
  get isMicMuted(): boolean { return this.muted; }
  set isMicMuted(v: boolean) {
    this.muted = v;
    Settings.micMuted = v;
    this.send("recorder:mute", v);
  }

  constructor() {
    const fromUs = (e: IpcMainEvent) => !!this.win && !this.win.isDestroyed() && e.sender === this.win.webContents;
    ipcMain.on("recorder:started", (e, info: { tracks: Track[]; inputRate: number }) => {
      if (!fromUs(e)) return;
      diag("Recorder", `capture started: ${info.tracks.join("+")} @ ${info.inputRate} Hz -> ${SAMPLE_RATE} Hz`);
      if (this.pendingStart) { this.pendingStart({ ok: true }); return; }
      // Started after we gave up waiting: stop it again.
      this.send("recorder:stop");
    });
    ipcMain.on("recorder:failed", (e, err: { stage: string; name: string; message: string }) => {
      if (!fromUs(e)) return;
      diag("Recorder", `capture failed (${err.stage}): ${err.name}: ${err.message}`);
      this.pendingStart?.({ ok: false, error: new RecorderError(err.message || err.name, err.stage, err.name) });
    });
    ipcMain.on("recorder:micUnavailable", (e, err: { name: string; message: string }) => {
      if (!fromUs(e)) return;
      let status = "unknown";
      try { if (isWin) status = systemPreferences.getMediaAccessStatus("microphone"); } catch { /* not supported */ }
      const blocked = err.name === "NotAllowedError" || err.name === "SecurityError" || status === "denied" || status === "restricted";
      diag("Recorder", `Mic capture unavailable: ${err.name}: ${err.message} (privacy: ${status}). Recording system audio only.`);
      const reason = err.name === "NotFoundError" || err.name === "OverconstrainedError"
        ? "No microphone found."
        : blocked ? "Windows is blocking microphone access." : (err.message || err.name);
      this.delegate?.recorderMicUnavailable?.(reason, blocked);
    });
    ipcMain.on("recorder:chunk", (e, track: Track, pcm: Uint8Array) => {
      if (!fromUs(e) || !this.capturing || !this.paths || !TRACKS.includes(track)) return;
      let w = this.writers.get(track);
      if (!w) {
        try { w = new WavWriter(this.paths[track], SAMPLE_RATE, 1); }
        catch (err) { diag("Recorder", `can't create ${this.paths[track]}: ${err}`); return; }
        this.writers.set(track, w);
      }
      w.write(Buffer.from(pcm.buffer, pcm.byteOffset, pcm.byteLength));
    });
    ipcMain.on("recorder:stopped", e => {
      if (!fromUs(e)) return;
      this.pendingStop?.();
    });
    ipcMain.on("recorder:log", (e, msg: string) => { if (fromUs(e)) diag("Recorder", String(msg)); });
  }

  /// Windows asks nobody for loopback audio and has no prompt to raise for the
  /// mic (a desktop app is either allowed by the privacy switch or not), so
  /// there's nothing to warm up. Logs the mic state for support logs.
  warmUpPermission(): void {
    if (!isWin) return;
    try { diag("Recorder", `microphone access: ${systemPreferences.getMediaAccessStatus("microphone")}`); }
    catch { /* not supported */ }
  }

  start(): void {
    if (this._isRecording || this.starting) return;
    this.starting = true;
    this.activeMode = this.captureMode;
    // If a previous stop() is still tearing down, wait for it to finish
    // before starting the new capture. Otherwise its finalize could close
    // the writers the new recording just opened.
    const prior = this.teardown;
    void (async () => {
      if (prior) await prior.catch(() => {});
      await this.beginCapture();
    })();
  }

  stop(): void {
    if (!this._isRecording) return;
    this._isRecording = false;
    const mode = this.activeMode;
    this.teardown = (async () => {
      await this.stopRenderer();
      // The capture renderer is only needed while recording; between
      // meetings it was a whole idle Chromium renderer. Next start makes one.
      if (this.win && !this.win.isDestroyed() && !this._isRecording) this.win.destroy();
      let artifacts: RecordingArtifacts | null = null;
      try { artifacts = await this.finalize(mode); }
      catch (e) { diag("Recorder", `finalize failed: ${e}`); }
      this.delegate?.recorderDidStop(artifacts, null);
    })();
  }

  private send(channel: string, ...args: unknown[]): void {
    if (this.win && !this.win.isDestroyed()) this.win.webContents.send(channel, ...args);
  }

  private async ensureWindow(): Promise<BrowserWindow> {
    if (this.win && !this.win.isDestroyed() && this.loaded) { await this.loaded; return this.win; }
    const win = new BrowserWindow({
      show: false,
      width: 320,
      height: 120,
      skipTaskbar: true,
      focusable: false,
      title: "Nikxel recorder",
      webPreferences: {
        preload: preloadPath("recorder"),
        contextIsolation: true,
        nodeIntegration: false,
        sandbox: true,
        session: recorderSession(),
        // A hidden window is throttled by default, and an AudioContext in a
        // page nobody clicked starts suspended without these.
        backgroundThrottling: false,
        autoplayPolicy: "no-user-gesture-required",
      },
    });
    this.win = win;
    win.webContents.on("render-process-gone", (_e, details) => {
      diag("Recorder", `recorder renderer gone: ${details.reason}`);
      this.rendererGone(win);
    });
    win.on("closed", () => { if (this.win === win) { this.win = null; this.loaded = null; } });
    this.loaded = win.loadFile(rendererPath("recorder"));
    try { await this.loaded; }
    catch (e) {
      this.loaded = null;
      if (!win.isDestroyed()) win.destroy();
      throw new RecorderError(`The recorder page didn't load: ${(e as Error).message}`, "window", "LoadError");
    }
    return win;
  }

  /// A crashed recorder page: fail a pending start, finish a pending stop, and
  /// for a recording in progress keep what was captured so far.
  private rendererGone(win: BrowserWindow): void {
    if (this.win === win) { this.win = null; this.loaded = null; }
    if (!win.isDestroyed()) win.destroy();
    this.pendingStart?.({ ok: false, error: new RecorderError("The recorder stopped unexpectedly.", "window", "Crash") });
    this.pendingStop?.();
    if (this._isRecording) this.stop();
  }

  private async beginCapture(): Promise<void> {
    try {
      const win = await this.ensureWindow();
      const dir = ensureDir(nikxelPath("recordings"));
      const stem = recordingStem(new Date());
      this.paths = {
        mix: path.join(dir, `${stem}.wav`),
        mic: path.join(dir, `${stem}_mic.wav`),
        sys: path.join(dir, `${stem}_sys.wav`),
      };
      this.writers.clear();
      this.capturing = true;
      const reply = await new Promise<StartReply>(resolve => {
        const timer = setTimeout(() => done({ ok: false, error: new RecorderError("Audio capture didn't start within 20 seconds.", "timeout", "Timeout") }), 20_000);
        const done = (r: StartReply) => { clearTimeout(timer); this.pendingStart = null; resolve(r); };
        this.pendingStart = done;
        win.webContents.send("recorder:start", { mode: this.activeMode, micMuted: this.muted });
      });
      if (!reply.ok) throw reply.error;
      this._isRecording = true;
      this.startedAt = new Date();
      this.delegate?.recorderDidStart();
    } catch (e) {
      diag("Recorder", `AudioRecorder error: ${e}`);
      await this.discard();
      this.delegate?.recorderDidStop(null, e instanceof Error ? e : new Error(String(e)));
    } finally {
      this.starting = false;
    }
  }

  /// Tells the page to stop and waits for its last chunks (bounded, so a
  /// wedged renderer can't hold the recording hostage).
  private stopRenderer(): Promise<void> {
    if (!this.win || this.win.isDestroyed()) return Promise.resolve();
    return new Promise(resolve => {
      const timer = setTimeout(() => { diag("Recorder", "recorder didn't confirm stop; finishing anyway"); done(); }, 10_000);
      const done = () => { clearTimeout(timer); this.pendingStop = null; resolve(); };
      this.pendingStop = done;
      this.send("recorder:stop");
    });
  }

  private async closeWriters(): Promise<void> {
    this.capturing = false;
    for (const [track, w] of this.writers) {
      try { await w.finish(); }
      catch (e) { diag("Recorder", `closing ${track} track failed: ${e}`); }
    }
  }

  /// A failed start: drop whatever was opened.
  private async discard(): Promise<void> {
    await this.closeWriters();
    for (const w of this.writers.values()) fs.promises.rm(w.path, { force: true }).catch(() => {});
    this.writers.clear();
  }

  private async finalize(mode: CaptureMode): Promise<RecordingArtifacts | null> {
    await this.closeWriters();
    const has = (t: Track): string | null => {
      const w = this.writers.get(t);
      return w && w.dataBytes > 0 && fs.existsSync(w.path) ? w.path : null;
    };
    const keep = new Set<string>();
    let artifacts: RecordingArtifacts | null = null;
    switch (mode) {
      case "notes": {
        // Already mixed in the graph -- no ffmpeg step needed.
        const mix = has("mix");
        if (mix) { artifacts = { kind: "merged", path: mix }; keep.add(mix); }
        break;
      }
      case "meeting": {
        // Keep tracks separate for per-speaker transcription.
        const sys = has("sys");
        if (sys) {
          const mic = has("mic");
          artifacts = { kind: "split", mic, sys };
          keep.add(sys);
          if (mic) keep.add(mic);
        }
        break;
      }
    }
    for (const w of this.writers.values()) if (!keep.has(w.path)) fs.promises.rm(w.path, { force: true }).catch(() => {});
    for (const w of this.writers.values()) {
      if (keep.has(w.path)) diag("Recorder", `${path.basename(w.path)}: ${w.durationSec.toFixed(1)} s`);
    }
    this.writers.clear();
    return artifacts;
  }
}
