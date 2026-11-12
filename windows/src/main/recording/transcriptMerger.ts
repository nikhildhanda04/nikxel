import * as fs from "fs";

/// Port of TranscriptMerger.swift.

export interface TranscriptSegment {
  start: number;
  end: number;
  text: string;
  speaker: string;
}

/// "HH:MM:SS,mmm" or "HH:MM:SS.mmm" -> seconds.
function parseSRTTime(s: string): number | null {
  const comps = s.replace(/,/g, ".").split(":");
  if (comps.length !== 3) return null;
  const [h, m, sec] = comps.map(c => (c.trim() === "" ? NaN : Number(c)));
  if (![h, m, sec].every(Number.isFinite)) return null;
  return h * 3600 + m * 60 + sec;
}

function formatTimestamp(seconds: number): string {
  const total = Math.trunc(seconds);
  const h = Math.trunc(total / 3600);
  const m = Math.trunc((total % 3600) / 60);
  const s = total % 60;
  const p = (n: number) => String(n).padStart(2, "0");
  return h > 0 ? `${p(h)}:${p(m)}:${p(s)}` : `${p(m)}:${p(s)}`;
}

export const TranscriptMerger = {
  /// Parse SRT, interleave by start time, render labeled transcript:
  ///   [00:00:05] Me: ...
  ///   [00:00:12] Others: ...
  merge(micSRT: string | null, sysSRT: string | null): string {
    const segments: TranscriptSegment[] = [];
    if (micSRT) segments.push(...TranscriptMerger.parse(micSRT, "Me"));
    if (sysSRT) segments.push(...TranscriptMerger.parse(sysSRT, "Others"));
    // Array.prototype.sort is stable, so equal start times keep Me before Others.
    segments.sort((a, b) => a.start - b.start);
    const lines: string[] = [];
    for (const s of segments) {
      const text = s.text.trim();
      if (!text) continue;
      lines.push(`[${formatTimestamp(s.start)}] ${s.speaker}: ${text}`);
    }
    return lines.join("\n");
  },

  parse(file: string, speaker: string): TranscriptSegment[] {
    let raw: string;
    try { raw = fs.readFileSync(file, "utf8"); } catch { return []; }
    return TranscriptMerger.parseText(raw, speaker);
  },

  parseText(raw: string, speaker: string): TranscriptSegment[] {
    // SRT blocks are separated by blank lines. Each block:
    //   <index>
    //   HH:MM:SS,mmm --> HH:MM:SS,mmm
    //   <text...>
    const blocks = raw.replace(/^﻿/, "").replace(/\r\n/g, "\n").split("\n\n");
    const out: TranscriptSegment[] = [];
    for (const block of blocks) {
      const lines = block.split("\n");
      if (lines.length < 2) continue;
      // Find the line with " --> " in it (skips index line; some emitters omit it).
      const tIdx = lines.findIndex(l => l.includes("-->"));
      if (tIdx < 0) continue;
      const parts = lines[tIdx].split("-->");
      if (parts.length !== 2) continue;
      const start = parseSRTTime(parts[0].trim());
      const end = parseSRTTime(parts[1].trim());
      if (start === null || end === null) continue;
      const text = lines.slice(tIdx + 1).join(" ").trim();
      if (!text) continue;
      out.push({ start, end, text, speaker });
    }
    return out;
  },
};
