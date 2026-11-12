import * as fs from "fs";
import { once } from "events";

/// Streams 16-bit PCM to a WAV file as it arrives, so an hour-long meeting
/// never sits in memory. The header is written with zero sizes up front and
/// patched with the real ones in finish().

export function wavHeader(dataBytes: number, sampleRate: number, channels: number): Buffer {
  const h = Buffer.alloc(44);
  const blockAlign = channels * 2;
  h.write("RIFF", 0, "ascii");
  h.writeUInt32LE(Math.min(0xffffffff, 36 + dataBytes), 4);
  h.write("WAVE", 8, "ascii");
  h.write("fmt ", 12, "ascii");
  h.writeUInt32LE(16, 16);                       // fmt chunk size
  h.writeUInt16LE(1, 20);                        // PCM
  h.writeUInt16LE(channels, 22);
  h.writeUInt32LE(sampleRate, 24);
  h.writeUInt32LE(sampleRate * blockAlign, 28);  // byte rate
  h.writeUInt16LE(blockAlign, 32);
  h.writeUInt16LE(16, 34);                       // bits per sample
  h.write("data", 36, "ascii");
  h.writeUInt32LE(Math.min(0xffffffff - 36, dataBytes), 40);
  return h;
}

export class WavWriter {
  private readonly stream: fs.WriteStream;
  private bytes = 0;
  private failed: Error | null = null;
  private finished: Promise<void> | null = null;

  constructor(readonly path: string, readonly sampleRate = 16000, readonly channels = 1) {
    this.stream = fs.createWriteStream(path);
    this.stream.on("error", e => { this.failed = e; });
    this.stream.write(wavHeader(0, sampleRate, channels));
  }

  get dataBytes(): number { return this.bytes; }
  get durationSec(): number { return this.bytes / (this.sampleRate * this.channels * 2); }

  write(pcm: Buffer): void {
    if (this.finished || this.failed) return;
    // Keep whole samples: an odd byte would shift every later sample.
    const usable = pcm.length - (pcm.length % 2);
    if (usable <= 0) return;
    this.bytes += usable;
    this.stream.write(usable === pcm.length ? pcm : pcm.subarray(0, usable));
  }

  /// Closes the file and writes the real sizes into the header.
  finish(): Promise<void> {
    this.finished ??= (async () => {
      if (!this.stream.closed) {
        const closed = once(this.stream, "close").catch(() => {});
        this.stream.end();
        await closed;
      }
      if (this.failed) throw this.failed;
      const fh = await fs.promises.open(this.path, "r+");
      try { await fh.write(wavHeader(this.bytes, this.sampleRate, this.channels), 0, 44, 0); }
      finally { await fh.close(); }
    })();
    return this.finished;
  }
}
