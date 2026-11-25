import { test } from "node:test";
import * as assert from "node:assert/strict";
import { analyse, describe, isPlaceholder } from "../main/recording/transcriptHealth";

/// Same cases as checks/check_transcript_health.swift.
test("transcript health: whisper stuck in a loop", () => {
  let stuck = "";
  const p = (n: number) => String(n).padStart(2, "0");
  for (let i = 0; i < 40; i++) stuck += `${i + 1}\n00:00:${p(i)},000 --> 00:00:${p(i + 1)},000\n ${i % 10 === 3 ? "Hello." : "[no audio]"}\n\n`;
  const s = analyse(stuck);
  assert.equal(s.segments, 40); assert.equal(s.placeholders, 36); assert.equal(s.words, 4);
  assert.equal(s.topPlaceholder, "[no audio]"); assert.equal(s.topLine, "hello."); assert.equal(s.topLineCount, 4);
  assert.equal(s.longestRun, 9); assert.equal(s.runLine, "[no audio]");
  assert.ok(describe(stuck).includes('36 placeholders (mostly "[no audio]")'));
});

test("transcript health: a normal transcript", () => {
  const fine = "1\r\n00:00:00,000 --> 00:00:03,000\r\nWe ship Friday.\r\n\r\n2\n00:00:03,000 --> 00:00:05,000\n(laughs) Sure, Ali.\n\n3\n00:00:05,000 --> 00:00:06,000\n[BLANK_AUDIO]\n";
  const f = analyse(fine);
  assert.equal(f.segments, 3); assert.equal(f.words, 5); assert.equal(f.placeholders, 1); assert.equal(f.longestRun, 1);
  assert.ok(!describe(fine).includes("longest run"));
  assert.ok(isPlaceholder("[BLANK_AUDIO]") && isPlaceholder("(music) [no audio]") && !isPlaceholder("(laughs) Sure"));
  assert.equal(analyse("").segments, 0);
});
