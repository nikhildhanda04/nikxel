// Runnable check for suggestions.ts — port of check_suggestions.swift.
import { test } from "node:test";
import * as assert from "node:assert/strict";
import { replies, switchesByHour, topPairs, afterMeetings } from "../main/system/suggestions";

const row = (t: number, name: string, preview: string) => ({ t, name, preview });

test("replies", () => {
  assert.deepEqual(replies([row(100, "Asha", "hi"), row(400, "Asha", "You: ok")], []),
    [{ chat: "Asha", group: false, incomingAt: 100, repliedAt: 400 }], "incoming then own: replied");
  assert.deepEqual(replies([row(100, "Asha", "hi"), row(220, "Asha", "hello?"), row(400, "Asha", "You: ok")], []),
    [{ chat: "Asha", group: false, incomingAt: 100, repliedAt: 400 }], "second incoming doesn't restart the wait");
  assert.deepEqual(replies([row(50, "Asha", "You: hey"), row(500, "Asha", "hi")], []),
    [{ chat: "Asha", group: false, incomingAt: 500, repliedAt: null }], "own first; open wait has no reply");
  const bot = [{ t: 240, name: "Asha", text: "Sure, I'll check" }];
  assert.deepEqual(replies([row(100, "Asha", "hi"), row(250, "Asha", "You: Sure, I'll check"), row(900, "Asha", "You: me now")], bot),
    [{ chat: "Asha", group: false, incomingAt: 100, repliedAt: 900 }], "bot's own reply doesn't close the wait");
  assert.deepEqual(replies([row(100, "Dev", "Ben: lunch?"), row(160, "Dev", "You: yes")], []),
    [{ chat: "Dev", group: true, incomingAt: 100, repliedAt: 160 }], "group chat detected");
  assert.deepEqual(replies([], []), [], "empty input");

  const open = [{ chat: "Asha", group: false, incomingAt: 100, repliedAt: null }];
  const replied = [{ chat: "Asha", group: false, incomingAt: 100, repliedAt: 250 }];
  const bots = (text: string, t = 240, name = "Asha") => [{ t, name, text }];
  assert.deepEqual(replies([row(100, "Asha", "hi"), row(250, "Asha", "You: Sure, I'll check it")], bots("Sure,\nI'll  check it")), open, "whitespace flattened: still the bot");
  const long = "abcdefghij".repeat(8);
  assert.deepEqual(replies([row(100, "Asha", "hi"), row(250, "Asha", "You: " + long.slice(0, 30) + "…")], bots(long)), open, "preview cut with an ellipsis: still the bot");
  assert.deepEqual(replies([row(100, "Asha", "hi"), row(250, "Asha", "You: ")], bots("Sure")), replied, "empty own text is a real reply");
  assert.deepEqual(replies([row(100, "Asha", "hi"), row(250, "Asha", "You:")], bots("Sure")), replied, 'bare "You:" is a real reply');
  assert.deepEqual(replies([row(100, "Asha", "hi"), row(250, "Asha", "You: Sure")], bots("Sure", 240, "Ben")), replied, "bot row for another chat: not matched");
  assert.deepEqual(replies([row(100, "Asha", "hi"), row(250, "Asha", "You: Sure")], bots("Sure", 551)), replied, "bot row 301s away: not matched");
  assert.deepEqual(replies([row(100, "Asha", "You: a"), row(200, "Asha", "You:")], []), [], "only own previews: nothing");
});

// Local-time dates, as habits.test.ts does, so the checks pass in any zone.
const at = (d: number, h: number, m: number) => new Date(2026, 0, d, h, m).getTime() / 1000;
const smp = (t: number, app: string) => ({ t, app, title: "" });

test("activity patterns", () => {
  const sw = [smp(at(5, 10, 0), "Code"), smp(at(5, 10, 10), "Slack"), smp(at(5, 10, 20), "Code"), smp(at(5, 10, 30), "Slack"), smp(at(5, 11, 0), "Code")];
  assert.deepEqual(switchesByHour(sw), { 10: 3, 11: 0 }, "switches per active hour; hour-boundary change not counted");
  assert.deepEqual(switchesByHour([...sw, smp(at(6, 10, 0), "Code"), smp(at(6, 10, 10), "Slack")]), { 10: 2, 11: 0 }, "average over days");
  assert.deepEqual(switchesByHour([smp(at(5, 10, 0), "Code"), smp(at(5, 10, 5), "LockApp"), smp(at(5, 10, 10), "Code")]), { 10: 0 }, "lock screen dropped");
  assert.deepEqual(switchesByHour([]), {}, "no samples: no hours");
  assert.deepEqual(topPairs(sw), [{ a: "Code", b: "Slack", count: 3 }], "pair Code/Slack x3 (a < b)");
  assert.deepEqual(topPairs([smp(1, "B"), smp(2, "A"), smp(3, "C")], 2), [{ a: "A", b: "B", count: 1 }, { a: "A", b: "C", count: 1 }], "ties by name, limited");
  assert.deepEqual(topPairs(sw, 0), [], "limit 0");
  const mt = (end: number) => ({ start: end - 3600, end, title: "m" });
  assert.deepEqual(afterMeetings([mt(1000), mt(10000)], [smp(1100, "Odoo"), smp(1200, "Odoo"), smp(1300, "Mail"), smp(10500, "Odoo"), smp(2800, "Late")]),
    [{ app: "Odoo", meetings: 2 }], "after two meetings: Odoo x2 once each; Mail x1 and 30 min edge dropped");
  assert.deepEqual(afterMeetings([], [smp(1, "A")]), [], "no meetings");
});
