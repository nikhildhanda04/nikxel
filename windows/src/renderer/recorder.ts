/// The hidden recorder window: the Windows stand-in for AudioRecorder's
/// ScreenCaptureKit stream and MicRecorder's AVAudioEngine tap.
///
///   system audio: getDisplayMedia, which main answers with the first screen
///                 plus WASAPI "loopback" audio; the video track is dropped.
///   microphone:   getUserMedia, raw (no echo cancellation / noise
///                 suppression / AGC), as AVAudioEngine delivered it.
///
/// Both feed one AudioContext, so their timelines are the same clock. An
/// AudioWorklet taps the graph, this page downsamples to 16 kHz mono 16-bit
/// (what whisper.cpp wants) and streams ~1 s chunks to main, which writes the
/// WAV files. Nothing accumulates here, so an hour-long meeting costs no more
/// memory than a minute.
///
///   Meeting mode: separate "mic" and "sys" tracks, transcribed separately
///                 and merged by timestamp ("Me" / "Others").
///   Notes mode:   one "mix" track, mixed in the graph (this replaces the
///                 Mac's ffmpeg amix step).

type Track = "mix" | "mic" | "sys";

interface RecorderBridge {
  onStart(cb: (opts: { mode: "notes" | "meeting"; micMuted: boolean }) => void): void;
  onStop(cb: () => void): void;
  onMute(cb: (muted: boolean) => void): void;
  started(info: { tracks: Track[]; inputRate: number }): void;
  failed(err: { stage: string; name: string; message: string }): void;
  micUnavailable(err: { name: string; message: string }): void;
  chunk(track: Track, pcm: Uint8Array): void;
  stopped(): void;
  log(msg: string): void;
}

declare global {
  interface Window { nikxelRecorder: RecorderBridge }
}

const api = window.nikxelRecorder;

const TARGET_RATE = 16000;
/// Samples per IPC message: one second.
const BATCH = TARGET_RATE;

/// Mic and system levels in the Notes mix. Mirrors the Mac's ffmpeg
/// `amix=inputs=2` (which divides each input by two) with `volume=1.5` on the mic.
const MIX_SYS_GAIN = 0.5;
const MIX_MIC_GAIN = 0.75;

/// Copies the (down-mixed mono) input into 4096-frame blocks and posts them.
/// With nothing connected it posts silence, so a track's timeline never
/// stalls. Loaded from a blob: URL so there's no extra file to ship.
const WORKLET = `
class NikxelTap extends AudioWorkletProcessor {
  constructor() {
    super();
    this.buf = new Float32Array(4096);
    this.n = 0;
    this.done = false;
    this.port.onmessage = (e) => {
      if (e.data === "flush") {
        const rest = this.buf.slice(0, this.n);
        this.n = 0;
        this.done = true;
        this.port.postMessage({ frames: rest, last: true }, [rest.buffer]);
      }
    };
  }
  process(inputs) {
    if (this.done) return false;
    const ch = inputs[0] && inputs[0][0];
    const len = ch ? ch.length : 128;
    for (let i = 0; i < len; i++) {
      this.buf[this.n++] = ch ? ch[i] : 0;
      if (this.n === this.buf.length) {
        const full = this.buf;
        this.buf = new Float32Array(4096);
        this.n = 0;
        this.port.postMessage({ frames: full, last: false }, [full.buffer]);
      }
    }
    return true;
  }
}
registerProcessor("nikxel-tap", NikxelTap);
`;

/// Box-filter decimation from the context's rate (48 kHz, 44.1 kHz, ...) to
/// 16 kHz: each output sample is the mean of the input samples that fall in
/// its slot, which doubles as the anti-alias filter. Stateful across blocks,
/// and repeats samples if a device ever runs below 16 kHz.
class Downsampler {
  private readonly ratio: number;
  private sum = 0;
  private count = 0;
  private inPos = 0;
  private outCount = 0;
  private batch = new Int16Array(BATCH);
  private n = 0;

  constructor(inRate: number, private readonly emit: (pcm: Uint8Array) => void) {
    this.ratio = inRate / TARGET_RATE;
  }

  push(frames: Float32Array): void {
    for (let k = 0; k < frames.length; k++) {
      this.sum += frames[k];
      this.count++;
      this.inPos++;
      if (this.inPos >= (this.outCount + 1) * this.ratio) {
        const v = this.sum / this.count;
        this.sum = 0;
        this.count = 0;
        do { this.put(v); this.outCount++; } while (this.inPos >= (this.outCount + 1) * this.ratio);
      }
    }
  }

  private put(v: number): void {
    const c = v < -1 ? -1 : v > 1 ? 1 : v;
    this.batch[this.n++] = c < 0 ? c * 0x8000 : c * 0x7fff;
    if (this.n === BATCH) this.flushBatch();
  }

  private flushBatch(): void {
    if (this.n === 0) return;
    this.emit(new Uint8Array(this.batch.buffer.slice(0, this.n * 2)));
    this.n = 0;
  }

  finish(): void {
    if (this.count > 0) { this.put(this.sum / this.count); this.sum = 0; this.count = 0; }
    this.flushBatch();
  }
}

interface Tap { track: Track; node: AudioWorkletNode; ds: Downsampler; flushed: Promise<void> }

interface Session {
  ctx: AudioContext;
  streams: MediaStream[];
  taps: Tap[];
  nodes: AudioNode[];
  micGain: GainNode | null;
  micBase: number;
}

let session: Session | null = null;
let starting = false;
let stopRequested = false;
let muted = false;

const errInfo = (e: unknown) => ({
  name: (e as { name?: string })?.name ?? "Error",
  message: (e as { message?: string })?.message ?? String(e),
});

function stopStreams(streams: MediaStream[]): void {
  for (const s of streams) for (const t of s.getTracks()) { try { t.stop(); } catch { /* already stopped */ } }
}

function makeTap(ctx: AudioContext, track: Track, sink: AudioNode): Tap {
  // channelCount 1 + explicit: the input is down-mixed to mono, and every
  // connection into it is summed, which is the Notes-mode mix.
  const node = new AudioWorkletNode(ctx, "nikxel-tap", {
    numberOfInputs: 1, numberOfOutputs: 1, outputChannelCount: [1],
    channelCount: 1, channelCountMode: "explicit", channelInterpretation: "speakers",
  });
  const ds = new Downsampler(ctx.sampleRate, pcm => api.chunk(track, pcm));
  let resolveFlushed!: () => void;
  const flushed = new Promise<void>(r => { resolveFlushed = r; });
  node.port.onmessage = (e: MessageEvent<{ frames: Float32Array; last: boolean }>) => {
    ds.push(e.data.frames);
    if (e.data.last) resolveFlushed();
  };
  // The tap's output is silence; routing it to the destination keeps the
  // node pulled by the graph on every render quantum.
  node.connect(sink);
  return { track, node, ds, flushed };
}

async function start(opts: { mode: "notes" | "meeting"; micMuted: boolean }): Promise<void> {
  if (session || starting) return;
  starting = true;
  stopRequested = false;
  muted = opts.micMuted;
  const streams: MediaStream[] = [];
  try {
    let sys: MediaStream;
    try {
      sys = await navigator.mediaDevices.getDisplayMedia({ video: true, audio: true });
    } catch (e) {
      api.failed({ stage: "system", ...errInfo(e) });
      return;
    }
    streams.push(sys);
    // Minimal video is required to get the stream; we discard it.
    for (const v of sys.getVideoTracks()) { v.stop(); sys.removeTrack(v); }
    if (sys.getAudioTracks().length === 0) {
      stopStreams(streams);
      api.failed({ stage: "system", name: "NoAudioTrack", message: "Windows didn't share any system audio." });
      return;
    }
    sys.getAudioTracks()[0].addEventListener("ended", () => api.log("system audio track ended"));

    // Mic capture runs in parallel. Failure to start is non-fatal --
    // recording continues with system audio only.
    let mic: MediaStream | null = null;
    try {
      mic = await navigator.mediaDevices.getUserMedia({
        audio: { echoCancellation: false, noiseSuppression: false, autoGainControl: false },
        video: false,
      });
      streams.push(mic);
      mic.getAudioTracks()[0]?.addEventListener("ended", () => api.log("microphone track ended (device unplugged?)"));
    } catch (e) {
      api.micUnavailable(errInfo(e));
    }

    const ctx = new AudioContext({ latencyHint: "playback" });
    const url = URL.createObjectURL(new Blob([WORKLET], { type: "text/javascript" }));
    try { await ctx.audioWorklet.addModule(url); } finally { URL.revokeObjectURL(url); }
    if (ctx.state !== "running") await ctx.resume().catch(() => {});

    const sink = ctx.createGain();
    sink.gain.value = 0;
    sink.connect(ctx.destination);

    const nodes: AudioNode[] = [sink];
    const taps: Tap[] = [];
    const sysSrc = ctx.createMediaStreamSource(sys);
    nodes.push(sysSrc);
    const micSrc = mic ? ctx.createMediaStreamSource(mic) : null;
    let micGain: GainNode | null = null;
    if (micSrc) {
      micGain = ctx.createGain();
      micSrc.connect(micGain);
      nodes.push(micSrc, micGain);
    }

    let micBase = 1;
    if (opts.mode === "notes") {
      const mixTap = makeTap(ctx, "mix", sink);
      const sysGain = ctx.createGain();
      sysGain.gain.value = MIX_SYS_GAIN;
      sysSrc.connect(sysGain).connect(mixTap.node);
      nodes.push(sysGain);
      if (micGain) { micBase = MIX_MIC_GAIN; micGain.connect(mixTap.node); }
      taps.push(mixTap);
    } else {
      // Separate tracks for per-speaker transcription.
      const sysTap = makeTap(ctx, "sys", sink);
      sysSrc.connect(sysTap.node);
      taps.push(sysTap);
      if (micGain) {
        const micTap = makeTap(ctx, "mic", sink);
        micGain.connect(micTap.node);
        taps.push(micTap);
      }
    }
    // Muted: the mic keeps recording silence, keeping its timeline aligned
    // with the system-audio one.
    if (micGain) micGain.gain.value = muted ? 0 : micBase;

    session = { ctx, streams, taps, nodes, micGain, micBase };
    api.started({ tracks: taps.map(t => t.track), inputRate: ctx.sampleRate });
    if (stopRequested) void stop();
  } catch (e) {
    stopStreams(streams);
    api.failed({ stage: "audio", ...errInfo(e) });
  } finally {
    starting = false;
  }
}

async function stop(): Promise<void> {
  if (starting) { stopRequested = true; return; }
  const s = session;
  session = null;
  if (!s) { api.stopped(); return; }
  try {
    // Ask each tap for its partial block, but don't hang the stop on it.
    for (const t of s.taps) t.node.port.postMessage("flush");
    await Promise.race([Promise.all(s.taps.map(t => t.flushed)), new Promise(r => setTimeout(r, 1000))]);
    for (const t of s.taps) { t.ds.finish(); t.node.port.onmessage = null; t.node.disconnect(); }
    for (const n of s.nodes) { try { n.disconnect(); } catch { /* not connected */ } }
    stopStreams(s.streams);
    await s.ctx.close().catch(() => {});
  } catch (e) {
    api.log(`stop: ${errInfo(e).message}`);
  } finally {
    api.stopped();
  }
}

api.onStart(opts => { void start(opts); });
api.onStop(() => { void stop(); });
api.onMute(m => {
  muted = m;
  if (session?.micGain) session.micGain.gain.value = m ? 0 : session.micBase;
});

export {};
