// Runnable check for habits.ts — port of check_habits.swift.
import { test } from "node:test";
import * as assert from "node:assert/strict";
import { clock, dayEnds, offerAutoRecord, parseRule, rulePrompt, summaryTime } from "../main/system/habits";

test("dayEnds: 6am-to-6am days, lock screen ignored, today left out", () => {
  const at = (day: number, h: number, m = 0) => new Date(2026, 10, day, h, m).getTime() / 1000;
  const ends = dayEnds([
    { t: at(10, 11), app: "Code" }, { t: at(10, 23), app: "Code" }, { t: at(11, 1, 30), app: "chrome" },
    { t: at(11, 3), app: "LockApp" },
    { t: at(11, 10), app: "Code" }, { t: at(11, 21), app: "Slack" },
    { t: at(12, 9), app: "Code" },
  ], new Date(2026, 10, 12, 15)).sort((a, b) => a - b);
  assert.deepEqual(ends, [1260, 1530]);
});

test("summaryTime", () => {
  assert.equal(summaryTime([1500, 1530, 1560, 1440, 1590, 1380, 1520], 1320), 1560, "median 1:20am → 2am");
  assert.equal(summaryTime([1500, 1530, 1560], 1320), null, "fewer than 7 days");
  assert.equal(summaryTime(Array(10).fill(1200), 1320), null, "done by 8pm: keep 10pm");
  assert.equal(summaryTime(Array(10).fill(1360), 1440), null, "within the hour of the current time");
  assert.equal(summaryTime(Array(10).fill(1440 + 400), 1320), 1440 + 300, "never past 5am");
  assert.equal(clock(1590), "2:30am"); assert.equal(clock(1380), "11pm"); assert.equal(clock(1440), "12am");
});

test("offerAutoRecord", () => {
  assert.ok(offerAutoRecord(5, 0)); assert.ok(offerAutoRecord(8, 2));
  assert.ok(!offerAutoRecord(4, 0)); assert.ok(!offerAutoRecord(6, 3));
});

test("rule prompt and parsing", () => {
  const p = rulePrompt(["merge related action items"], ["Keep it short"]);
  assert.ok(p.includes("merge related action items") && p.includes("- Keep it short") && p.includes("NONE"));
  assert.deepEqual(parseRule('{"rule": "Merge related action items into one.", "times": 3, "example": "merge 2 and 4"}'),
    { rule: "Merge related action items into one.", times: 3, example: "merge 2 and 4" });
  assert.equal(parseRule("NONE"), null);
  assert.equal(parseRule('{"rule": "x", "times": 1, "example": ""}'), null, "asked once");
  assert.equal(parseRule('Sure! {"rule": "Be brief.", "times": 2}')?.rule, "Be brief.", "JSON inside prose");
});
