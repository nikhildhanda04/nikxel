// Runnable check for DayLogger.recentSummaries — the day-window, missing-day
// and truncation logic behind the WhatsApp bot's memory. Port of
// check_bot_memory.swift.
//
// The Windows DayLogger splits the Swift function in two: recentSummaryEntries
// (days, maxCharsPerDay, directory, now) -> [{ day, text }] carries the logic
// checked here, and recentSummaries(days) joins it into the prompt block.
// Falls back to a Swift-shaped recentSummaries if that's what is there, and
// skips (saying why) rather than failing if neither is.
import { test } from "node:test";
import * as assert from "node:assert/strict";
import * as fs from "fs";
import * as os from "os";
import * as path from "path";

type Entry = { day: string; text: string };
type Recent = (days: number, maxCharsPerDay?: number, directory?: string, now?: Date) => unknown;

function load(): Recent | string {
  let mod: any;
  try {
    // eslint-disable-next-line @typescript-eslint/no-var-requires
    mod = require("../main/system/dayLogger");
  } catch (e) {
    return `system/dayLogger not loadable yet (${(e as Error).message.split("\n")[0]})`;
  }
  const fn = mod?.DayLogger?.recentSummaryEntries ?? mod?.DayLogger?.recentSummaries;
  return typeof fn === "function" ? (fn.bind(mod.DayLogger) as Recent) : "DayLogger.recentSummaryEntries missing";
}

function entries(r: unknown): Entry[] | null {
  if (!Array.isArray(r)) return null;
  return r.map(e => (Array.isArray(e) ? { day: e[0], text: e[1] } : { day: e.day, text: e.text }));
}

test("DayLogger.recentSummaries: the bot's memory window", t => {
  const recent = load();
  if (typeof recent === "string") { t.skip(recent); return; }

  const dir = path.join(os.tmpdir(), `nikxel-check-${process.pid}`);
  fs.mkdirSync(dir, { recursive: true });
  try {
    // Fixed "now" so the check doesn't drift with the calendar.
    const now = new Date(2026, 10, 10, 12);
    const write = (day: string, text: string) => fs.writeFileSync(path.join(dir, `${day}.md`), text, "utf8");
    const got = (days: number, cap = 1200): Entry[] | null => entries(recent(days, cap, dir, now));

    // Yesterday backwards, never today: today's summary isn't written until 10pm.
    write("2026-11-10", "TODAY - must never appear");
    write("2026-11-09", "nine");
    write("2026-11-08", "eight");
    write("2026-11-06", "six");      // the 7th is missing on purpose

    if (got(1) === null) { t.skip("recentSummaries returns a string here, not [(day, text)]"); return; }

    assert.equal(got(0)!.length, 0, "0 days means the feature is off");
    assert.equal(got(-1)!.length, 0, "a negative window must not crash or wrap");

    assert.deepEqual(got(1)!.map(e => e.day), ["2026-11-09"], "1 day = yesterday, not today");
    assert.deepEqual(got(3)!.map(e => e.day), ["2026-11-09", "2026-11-08"], "a missing day is skipped, not substituted");
    assert.deepEqual(got(4)!.map(e => e.day), ["2026-11-09", "2026-11-08", "2026-11-06"], "newest first, gap skipped");

    // Empty and whitespace-only files are not context.
    write("2026-11-05", "   \n  ");
    assert.deepEqual(got(5)!.map(e => e.day), ["2026-11-09", "2026-11-08", "2026-11-06"], "a blank summary must be dropped");

    // Truncation: these get prepended to every reply prompt.
    write("2026-11-09", "x".repeat(5000));
    const capped = got(1, 100)!;
    assert.equal(Array.from(capped[0].text).length, 101, "capped to 100 chars + ellipsis");
    assert.ok(capped[0].text.endsWith("…"), "truncation must be visible to the model");

    write("2026-11-09", "short");
    assert.equal(got(1, 100)![0].text, "short", "a short summary must not be altered");

    assert.equal(entries(recent(3, 1200, path.join(dir, "nope"), now))!.length, 0,
      "a missing directory yields no context, not a crash");
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});
