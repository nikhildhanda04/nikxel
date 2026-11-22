// Runnable check for suggestions.ts — port of check_suggestions.swift.
import { test } from "node:test";
import * as assert from "node:assert/strict";
import { replies, switchesByHour, topPairs, afterMeetings, digest, parse, key, type Settings, type Input } from "../main/system/suggestions";

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

const st: Settings = { summaryMinutes: 1320, autoRecordCalls: true, waDraftOnly: false, waQuietHours: true, waQuietFrom: 22, waQuietTo: 8,
  waChatTasks: true, summaryTemplate: "default", templates: ["default", "sales"] };
const items = (json: string, answered = new Set<string>()) => parse(json, st, answered);
const offer = (action: string, params: string) => `{"kind":"offer","action":"${action}","params":${params},"line":"I'm thinking of it","evidence":"e"}`;
const advice = `{"kind":"advice","text":"Batch Slack","evidence":"40 switches/h"}`;

test("digest, catalogue and the AI's reply", () => {
  assert.deepEqual(items(`Sure! Here you go:\n\`\`\`json\n{"items":[${advice},${offer("summaryTime", `{"minutes":1560}`)}]}\n\`\`\`\nHope it helps.`),
    [{ kind: "advice", text: "Batch Slack", evidence: "40 switches/h" },
     { kind: "offer", action: "summaryTime", params: { minutes: "1560" }, line: "I'm thinking of it", evidence: "e" }], "prose and fence around: advice and summaryTime kept");
  assert.deepEqual(items(`{"items":[${offer("postToSlack", "{}")}]}`), [], "action outside the catalogue dropped");
  assert.deepEqual(items(`{"items":[${offer("waQuietHours", `{"from":22,"to":8}`)}]}`), [], "quiet hours as they are: no-op dropped");
  assert.deepEqual(items(`{"items":[${offer("waQuietHours", `{"from":"21","to":8}`)}]}`),
    [{ kind: "offer", action: "waQuietHours", params: { from: "21", to: "8" }, line: "I'm thinking of it", evidence: "e" }], "quiet hours changed: kept (string or number)");
  assert.deepEqual(items(`{"items":[${offer("summaryTemplate", `{"name":"legal"}`)}]}`), [], "template not installed dropped");
  assert.deepEqual(items(`{"items":[${offer("autoRecordCalls", "{}")}]}`), [], "autoRecordCalls already on dropped");
  assert.deepEqual(items(`{"items":[${offer("summaryRule", `{"text":"Lead with decisions"}`)}]}`, new Set(["rule:Lead with decisions"])), [], "answered rule dropped");
  assert.equal(items(`{"items":[${Array(5).fill(advice).join(",")}]}`).length, 3, "at most 3");
  assert.deepEqual(items("NONE"), [], "NONE: nothing");
  assert.deepEqual(items(`{"items":[${offer("summaryTime", `{"minutes":1560.5}`)},${offer("summaryTime", `{"minutes":1320}`)}]}`), [], "fractional minutes and current time dropped");
  assert.equal(key("waQuietHours", { to: "8", from: "21" }), "weekly:waQuietHours:from=21,to=8", "key sorts params");
  assert.equal(key("summaryRule", { text: "Lead with decisions" }), "rule:Lead with decisions", "rule key shared with the daily check");

  const title = "0123456789".repeat(20);
  const input: Input = { samples: [{ t: at(5, 10, 0), app: "Code", title }, { t: at(5, 10, 1), app: "Slack", title: "general" }],
    meetings: [{ start: at(5, 9, 0), end: at(5, 9, 30), title: "Standup" }, { start: at(6, 9, 0), end: at(6, 9, 30), title: "Standup" }],
    chats: [row(at(5, 10, 0), "Asha", "pineapple pie"), row(at(5, 10, 30), "Asha", "You: mango"), row(at(5, 11, 0), "Ben", "hey")],
    bot: [], edits: ["Put decisions first"], erp: [{ day: "2026-01-05", name: "Fix invoice export", project: "Acme" }], settings: st, declined: ["weekly:waDraftOnly:"] };
  const dg = digest(input);
  assert.ok(dg.includes(title.slice(0, 90)) && !dg.includes(title.slice(0, 91)) && dg.includes("Code"), "digest: titles cut to 90");
  assert.ok(!dg.includes("pineapple") && !dg.includes("mango") && dg.includes("Asha"), "digest: chat names but no message text");
  const dc = digest({ ...input, declined: Array.from({ length: 35 }, (_, n) => `k${n}`),
    samples: [{ t: at(5, 10, 0), app: "Code", title: "" }, { t: at(5, 10, 20), app: "Slack", title: "" }, { t: at(5, 10, 22), app: "LockApp", title: "" }, { t: at(5, 10, 40), app: "Slack", title: "" }] });
  assert.ok(dc.includes("- Code: 5 min\n- Slack: 2 min\n") && dc.includes("10:00–10:40"), "digest: gap capped at 5 min, lock screen counts nothing, last sample 15s");
  assert.ok(dc.includes("- k5\n") && !dc.includes("- k4\n"), "digest: latest 30 answered keys");
  assert.equal(dg, "Minutes per app (top 10):\n" +
    "- Code: 1 min\n" +
    "- Slack: 0 min\n" +
    "\n" +
    "Minutes per window title (top 10):\n" +
    "- Code — 012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789: 1 min\n" +
    "- Slack — general: 0 min\n" +
    "\n" +
    "First and last activity per day:\n" +
    "- 2026-01-05: 10:00–10:01\n" +
    "\n" +
    "App switches per hour of day (average per active hour):\n" +
    "- 10:00: 1.0\n" +
    "\n" +
    "Most frequent back-and-forth app pairs:\n" +
    "- Code ↔ Slack x1\n" +
    "\n" +
    "Meetings (2 this week):\n" +
    "- start hours: 09:00 x2\n" +
    "- recurring titles: Standup x2\n" +
    "- apps opened within 30 min after a meeting: (none)\n" +
    "\n" +
    "WhatsApp reply waits (median minutes, replied messages; 1 replied, 1 unanswered):\n" +
    "- by hour the message arrived: 10:00 30\n" +
    "- 1:1 vs group: 1:1 30\n" +
    "- 5 slowest chats: Asha 30\n" +
    "- unanswered by day: 2026-01-05 1\n" +
    "\n" +
    "Fixes typed into meeting summaries (last 20):\n" +
    "- Put decisions first\n" +
    "\n" +
    "ERP tasks logged (last 40):\n" +
    "- 2026-01-05 Fix invoice export (Acme)\n" +
    "\n" +
    "Current settings:\n" +
    "- summary time: 10pm (minutes=1320)\n" +
    "- auto-record calls: on\n" +
    "- WhatsApp draft-only: off\n" +
    "- WhatsApp quiet hours: on, from 22 to 8\n" +
    "- WhatsApp chat tasks: on\n" +
    "- summary template: default (installed: default, sales)\n" +
    "\n" +
    "Already answered -- don't suggest these again (latest 30):\n" +
    "- weekly:waDraftOnly:", "digest: whole text, same as the Swift check");
});
