// Port of check_chat_context.swift.
import { test } from "node:test";
import * as assert from "node:assert/strict";
import * as fs from "fs";
import * as os from "os";
import * as path from "path";
import { localBlocks, projectBlocks, build, prompt, clickDecision, openTarget, Block, CAP } from "../main/system/chatContext";

const ymd = (d: Date) => `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`;
const today = new Date();
const day = (n: number) => ymd(new Date(today.getFullYear(), today.getMonth(), today.getDate() - n));

test("ChatContext: local blocks, cap rule, prompt", () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "nikxel-cc-"));
  const put = (rel: string, s: string) => { const f = path.join(root, rel); fs.mkdirSync(path.dirname(f), { recursive: true }); fs.writeFileSync(f, s); };
  put(`daily/${day(0)}.md`, "daily body");
  put(`meetings/${day(1)}-101500.md`, "meeting body");
  put(`meetings/${day(1)}-101500.transcript.txt`, "transcript");
  put(`notes/${day(20)}-0900.md`, "old note");
  put("notes/junk.md", "junk");
  const bs = localBlocks(root, today);
  assert.deepEqual(bs.map((b) => b.kind), ["daily", "meeting"]);
  assert.equal(bs[0].date, day(0));
  assert.equal(bs[1].name, `${day(1)}-101500`);
  fs.rmSync(path.join(root, "notes"), { recursive: true });
  assert.equal(localBlocks(root, today).length, 2, "missing notes folder");
  assert.deepEqual(localBlocks(path.join(root, "nope"), today), []);

  const pad = "x".repeat(60);
  const old: Block = { kind: "daily", date: day(10), name: day(10), text: pad };
  const mtg: Block = { kind: "meeting", date: day(3), name: "m", text: pad };
  const dly: Block = { kind: "daily", date: day(0), name: day(0), text: pad };
  const out = build([old, mtg, dly], 200);
  assert.ok(out.length <= 200 && !out.includes(day(10)) && out.includes(`### meeting · ${day(3)} · m`) && out.includes(`### daily · ${day(0)}`));
  assert.ok(out.indexOf("### daily") < out.indexOf("### meeting"), "newest first");
  assert.ok(build([mtg, dly], 50).length <= 50);
  const pb = projectBlocks([{ id: "p", name: "POS", days: [{ date: "2026-11-20", meetings: [{ title: "Sync", body: "b", name: "Ravi" }], items: [{ what: "Fixed login", section: "x", name: null }] }] }]);
  assert.ok(pb.length === 1 && pb[0].kind === "project" && pb[0].name === "POS" && pb[0].text.includes("Sync") && pb[0].text.includes("Fixed login"));

  const p = prompt("CTX", [{ q: "first?", a: "one" }], "second?", today);
  assert.ok(p.includes(day(0)) && p.includes("first?") && p.includes("one") && p.endsWith("second?"));
});

test("clickDecision: under 4 pt with no second click opens the chat", () => {
  assert.equal(clickDecision(0, false), "chat");
  assert.equal(clickDecision(3.9, false), "chat");
  assert.equal(clickDecision(5, false), "none");
  assert.equal(clickDecision(0, true), "none");
});

test("build: 350 x 10k blocks fit under the cap", () => {
  const big: Block[] = Array.from({ length: 350 }, (_, i) => ({ kind: i % 3 === 0 ? "daily" : "meeting", date: day(i % 14), name: `b${i}`, text: "y".repeat(10_000) }));
  const out = build(big, CAP);
  assert.ok(out.length <= CAP && out.length > CAP - 10_100);
});

test("openTarget: which summary a chat question asks to open", () => {
  const lib = [{ kind: "daily", title: "Tue 25 Nov" }, { kind: "meetings", title: "Nikxel product sync" },
    { kind: "meetings", title: "Sarvam Voice Agent Dashboard Integration" }, { kind: "weekly", title: "Week to 22 Nov" }];
  assert.equal(openTarget("can you open the latest meeting summary that was made", lib), 1);
  assert.equal(openTarget("open the Sarvam minutes", lib), 2);
  assert.equal(openTarget("show me my last daily summary", lib), 0);
  assert.equal(openTarget("open the weekly recap", lib), 3);
  assert.equal(openTarget("open the Zebra meeting", lib), null);
  assert.equal(openTarget("what did Piyush say in the last meeting?", lib), null);
  assert.equal(openTarget("open whatsapp", lib), null);
});
