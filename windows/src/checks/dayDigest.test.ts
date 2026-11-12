// Checks the end-of-day digest line: app classification, duration wording, and
// which combinations of stats are worth a bubble at all. Port of
// check_day_digest.swift. (Its MeetingCoordinator.firstBullets cases belong to
// the recording module's checks.)
import { test } from "node:test";
import * as assert from "node:assert/strict";
import { DayLogger, emptyStats as S } from "../main/system/dayLogger";

test("duration wording", () => {
  assert.equal(DayLogger.humanDuration(200), "3h 20m");
  assert.equal(DayLogger.humanDuration(45), "45m");
  assert.equal(DayLogger.humanDuration(120), "2h", "a whole number of hours drops the 0m");
  assert.equal(DayLogger.humanDuration(0), "0m");
  assert.equal(DayLogger.humanDuration(61), "1h 1m");
});

test("digest line", () => {
  // The line in the mock.
  assert.equal(DayLogger.digestLine(S({ codingSeconds: 200 * 60, activeSeconds: 400 * 60, meetings: 2, messages: 41 })),
    "3h 20m coding · 2 meetings · 41 messages");
  // Singulars.
  assert.equal(DayLogger.digestLine(S({ codingSeconds: 60 * 60, activeSeconds: 90 * 60, meetings: 1, messages: 1 })),
    "1h coding · 1 meeting · 1 message");
  // Zero parts are dropped, not shown as "0 meetings".
  assert.equal(DayLogger.digestLine(S({ codingSeconds: 95 * 60, activeSeconds: 300 * 60, meetings: 0, messages: 12 })),
    "1h 35m coding · 12 messages");
  // Somebody who never codes still gets a useful bubble.
  assert.equal(DayLogger.digestLine(S({ codingSeconds: 0, activeSeconds: 420 * 60, meetings: 4, messages: 63 })),
    "4 meetings · 63 messages");
  // Under a minute of coding isn't "0m coding".
  assert.equal(DayLogger.digestLine(S({ codingSeconds: 20, activeSeconds: 200 * 60 })), "3h 20m at the PC");
  // Fallback and silence.
  assert.equal(DayLogger.digestLine(S({ activeSeconds: 125 * 60 })), "2h 5m at the PC");
  assert.equal(DayLogger.digestLine(S({ activeSeconds: 12 * 60 })), null, "under half an hour with nothing else = no bubble");
  assert.equal(DayLogger.digestLine(S()), null, "an empty day must not produce a bubble");
  // Right on the half-hour boundary the fallback kicks in.
  assert.equal(DayLogger.digestLine(S({ activeSeconds: 30 * 60 })), "30m at the PC");
  assert.equal(DayLogger.digestLine(S({ activeSeconds: 29 * 60 })), null);
});

test("coding-app classification", () => {
  for (const name of ["Visual Studio Code", "Code - Insiders", "VSCodium", "Xcode", "Cursor",
    "Terminal", "iTerm2", "Ghostty", "Warp", "Zed", "Sublime Text",
    "IntelliJ IDEA", "PyCharm", "Android Studio", "Antigravity", "Kiro",
    // Windows file descriptions and exe names
    "Windows Terminal", "WindowsTerminal", "Windows PowerShell", "pwsh", "Windows Command Processor",
    "Microsoft Visual Studio 2022", "idea64", "Code", "Notepad++", "Git Bash"]) {
    assert.ok(DayLogger.isCodingApp(name), `${name} should count as coding`);
  }
  for (const name of ["Safari", "Google Chrome", "Slack", "Notion", "Spotify", "Mail",
    "Figma", "Zoom", "WhatsApp", "Preview", "Finder", "Nikxel",
    "Microsoft Edge", "Windows Explorer", "Microsoft Teams", "Microsoft Outlook", "Notepad", "Microsoft Word"]) {
    assert.ok(!DayLogger.isCodingApp(name), `${name} should NOT count as coding`);
  }
  // Matching is case-insensitive, since app names arrive as display names.
  assert.ok(DayLogger.isCodingApp("TERMINAL") && DayLogger.isCodingApp("xcode"));
});

test("git helpers", () => {
  assert.deepEqual(DayLogger.hunkContexts("@@ -1,2 +1,3 @@ export function buildSaleBody(\n+x\n@@ -9 +9 @@\n@@ -20 +20 @@ export function buildSaleBody(\n"),
    ["export function buildSaleBody("]);
  assert.ok(DayLogger.isNoiseFile("web/package-lock.json") && DayLogger.isNoiseFile("Thumbs.db") && DayLogger.isNoiseFile("a\\.DS_Store"));
  assert.ok(!DayLogger.isNoiseFile("src/main.ts"));
  assert.equal(DayLogger.redactSecrets("key sk_live_abcdefghijklmnop1234 <pasted_content id=1>ok"), "key [redacted] ok");
});

test("messages are preview changes, not snapshots", () => {
  const snap = (name: string, preview: string) => ({ name, preview });
  assert.equal(DayLogger.countMessages([
    snap("Priya", "old"), snap("Rahul", "hi"),   // already there at start
    snap("Priya", "old"), snap("Rahul", "hi"),   // same poll again
    snap("Priya", "invoice?"), snap("Rahul", "hi"),
    snap("Priya", "invoice?"), snap("Rahul", "call me"),
    snap("Rahul", "typing…"), snap("Rahul", "call me"), // flipping back adds nothing
  ]), 3);
  assert.equal(DayLogger.countMessages([]), 0);
});
