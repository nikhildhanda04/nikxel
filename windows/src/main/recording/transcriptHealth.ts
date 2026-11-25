/// One log line on how a whisper transcript came out, so a meeting that
/// turned into nothing can be traced afterwards: how many segments and words,
/// how many segments are only a placeholder ("[no audio]", "[BLANK_AUDIO]",
/// "(music)"), the line repeated most, and the longest run of the same line --
/// the signature of whisper stuck in a loop (2026-11-25: "[no audio]" for 280
/// segments of a 55-minute meeting full of speech). Port of TranscriptHealth.swift.

export interface Report {
  segments: number; words: number; placeholders: number;
  topPlaceholder: string; topLine: string; topLineCount: number;
  longestRun: number; runLine: string;
}

/// The spoken lines of an .srt or .txt: no cue numbers, no timestamps, no blanks.
export function lines(text: string): string[] {
  return text.split(/\r?\n/).map(l => l.trim()).filter(l => l && !l.includes("-->") && !/^\d+$/.test(l));
}

export function isPlaceholder(line: string): boolean {
  return /^([[(][^\])]*[\])]\s*)+$/.test(line);
}

function top(counts: Map<string, number>): [string, number] {
  let best: [string, number] = ["", 0];
  for (const [k, v] of counts) if (v > best[1] || (v === best[1] && k < best[0])) best = [k, v];
  return best;
}

export function analyse(text: string): Report {
  const r: Report = { segments: 0, words: 0, placeholders: 0, topPlaceholder: "", topLine: "", topLineCount: 0, longestRun: 0, runLine: "" };
  const counts = new Map<string, number>(), placeholderCounts = new Map<string, number>();
  let run = 0, previous = "";
  for (const line of lines(text)) {
    r.segments++;
    if (isPlaceholder(line)) {
      r.placeholders++;
      placeholderCounts.set(line, (placeholderCounts.get(line) ?? 0) + 1);
    } else {
      r.words += line.replace(/\[[^\]]*\]|\([^)]*\)/g, " ").split(/\s+/).filter(Boolean).length;
      const k = line.toLowerCase();
      counts.set(k, (counts.get(k) ?? 0) + 1);
    }
    run = line === previous ? run + 1 : 1;
    previous = line;
    if (run > r.longestRun) { r.longestRun = run; r.runLine = line; }
  }
  r.topPlaceholder = top(placeholderCounts)[0];
  [r.topLine, r.topLineCount] = top(counts);
  return r;
}

/// "280 segments, 3 words, 277 placeholders (mostly "[no audio]"), top line "hello." ×3, longest run 264× "[no audio]""
export function describe(text: string): string {
  const r = analyse(text);
  let s = `${r.segments} segments, ${r.words} words`;
  if (r.placeholders > 0) s += `, ${r.placeholders} placeholders (mostly "${r.topPlaceholder}")`;
  if (r.topLineCount > 1) s += `, top line "${r.topLine.slice(0, 60)}" ×${r.topLineCount}`;
  if (r.longestRun > 2) s += `, longest run ${r.longestRun}× "${r.runLine.slice(0, 60)}"`;
  return s;
}
