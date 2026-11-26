// Port of checks/check_automation.swift.
import { test } from "node:test";
import * as assert from "node:assert/strict";
import * as fs from "fs";
import * as os from "os";
import * as path from "path";
import * as A from "../main/system/automation";

test("Automation: schedule, clean, parse, ideas, store", () => {
  // 2026-11-27 is a Friday. The checks read the clock in UTC, like the Swift's calendar.
  const fri9 = new Date("2026-11-27T09:00:00Z"), sat9 = new Date("2026-11-28T09:00:00Z");
  const a = A.make({ id: "x", name: "Brief", trigger: "schedule", time: "09:00", days: "weekdays", instruction: "Brief me" });
  assert.ok(A.due(a, fri9, true) && !A.due(a, sat9, true), "weekdays: Friday yes, Saturday no");
  assert.ok(!A.due(a, new Date("2026-11-27T09:01:00Z"), true), "only in its minute");
  a.days = "fri"; assert.ok(A.due(a, fri9, true), "named weekday");
  a.enabled = false; assert.ok(!A.due(a, fri9, true), "disabled never runs");
  a.enabled = true; a.trigger = "meeting"; assert.ok(!A.due(a, fri9, true), "event triggers aren't scheduled");

  const bad = A.clean(A.make({ id: "", name: "", trigger: "hourly", time: "25:99", days: "someday", instruction: "  Do it  " }));
  assert.ok(bad?.trigger === "schedule" && bad.time === "09:00" && bad.days === "daily" && bad.name === "Do it" && bad.id !== "", "clean fixes trigger, time, days, name, id");
  assert.equal(A.clean(A.make({ id: "", name: "x", trigger: "day", instruction: " " })), null, "no instruction, no automation");
  assert.equal(A.clean(A.make({ id: "", name: "x", trigger: "schedule", time: "7:5", instruction: "y" }))?.time, "07:05", "time padded");

  const one = A.parse("Sure! {\"name\":\"Follow up\",\"trigger\":\"meeting\",\"instruction\":\"Draft it\"} done");
  assert.ok(one.length === 1 && one[0].a.trigger === "meeting", "one object out of prose");
  const many = A.parse("```json\n[{\"name\":\"A\",\"trigger\":\"schedule\",\"time\":\"17:00\",\"days\":\"Fri\",\"instruction\":\"x\",\"why\":\"Fridays\"},{\"name\":\"B\",\"instruction\":\"\"}]\n```");
  assert.ok(many.length === 1 && many[0].a.days === "fri" && many[0].why === "Fridays", "array, empty one dropped, days lowercased");
  assert.equal(A.parse("no json here").length, 0, "nothing to parse");
  assert.ok(A.IDEAS.every(i => A.clean(i) !== null), "every idea is valid");
  assert.equal(A.when(A.make({ id: "", name: "", trigger: "schedule", time: "17:00", days: "fri", instruction: "" })), "Every Friday at 17:00", "when label");

  const tmp = path.join(os.tmpdir(), `au-${process.pid}-${Date.now()}.json`);
  A.store.file = tmp;
  A.save([a]);
  assert.deepEqual(A.load(), [a], "saved and loaded");
  fs.rmSync(tmp, { force: true });
});

test("Automation: one-time (temporary) ones and reminder requests", () => {
  const sat9 = new Date("2026-11-28T09:00:00Z");
  const once = A.make({ id: "r", name: "Remind: call Vikas", trigger: "schedule", time: "09:00", instruction: "Remind me", date: "2026-11-28" });
  assert.ok(!A.due(once, new Date("2026-11-27T09:00:00Z"), true), "once: not the day before");
  assert.ok(A.due(once, sat9, true) && A.due(once, new Date("2026-11-28T14:30:00Z"), true), "once: on time, and late");
  once.lastRun = "2026-11-28 09:00"; assert.ok(!A.due(once, new Date("2026-11-29T09:00:00Z"), true), "once: never twice");
  assert.equal(A.clean(A.make({ trigger: "meeting", instruction: "y", date: "2026-11-28" }))?.date, null, "only a schedule has a date");
  assert.equal(A.clean(A.make({ trigger: "schedule", instruction: "y", date: "tomorrow" }))?.date, null, "a bad date is dropped");
  assert.equal(A.parse(`{"name":"Remind","trigger":"schedule","time":"9:00","date":"2026-11-28","instruction":"Remind me"}`)[0]?.a.date, "2026-11-28", "date parsed");
  assert.ok(A.looksLikeReminder("remind me tomorrow morning to send the deck") && A.looksLikeReminder("Can you set a reminder for 5pm?")
    && !A.looksLikeReminder("what reminders do I have?") && !A.looksLikeReminder("he reminded me of the deal"), "reminder requests, not questions");
  const tmp = path.join(os.tmpdir(), `au-${process.pid}-once.json`);
  A.store.file = tmp;
  A.save([once, A.make({ id: "d", trigger: "day", instruction: "i" })]);
  const back = A.load();
  assert.equal(back[0].date, "2026-11-28"); assert.equal(back[1].date, null, "saved and loaded, date only where set");
  assert.ok(!/"date"/.test(fs.readFileSync(tmp, "utf8").split("},")[1]), "no date key on a repeating one, like the Mac");
  fs.rmSync(tmp, { force: true });
});
