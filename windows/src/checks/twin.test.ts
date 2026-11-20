// Runnable check for TwinProfile — port of check_twin.swift. Skips (saying why)
// if the module isn't loadable yet.
import { test } from "node:test";
import * as assert from "node:assert/strict";
import * as fs from "fs";
import * as os from "os";
import * as path from "path";

const LABEL = "What Nikxel has learned about this user over time — their work, the correct names and terms they use, and how they talk and write. Match it.";

test("TwinProfile: learned store and injected block", t => {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), "nikxel-twin-"));
  process.env.HOME = home; process.env.USERPROFILE = home; // before paths.ts reads os.homedir()
  let TP: any;
  try {
    // eslint-disable-next-line @typescript-eslint/no-var-requires
    TP = require("../main/system/twinProfile").TwinProfile;
  } catch (e) { t.skip(`system/twinProfile not loadable yet (${(e as Error).message.split("\n")[0]})`); return; }

  TP.learned = "";
  assert.equal(TP.injectedBlock, "");

  TP.learned = "Works on Vizion Tools.";
  assert.ok(TP.injectedBlock.includes(LABEL) && TP.injectedBlock.includes("Works on Vizion Tools."));

  TP.learned = "Keep this.\n<!--corrections-->SECRET<!--/corrections-->\nAnd this.";
  const b: string = TP.injectedBlock;
  assert.ok(!b.includes("SECRET") && !b.includes("corrections") && b.includes("Keep this.") && b.includes("And this."));

  TP.learned = "";
  assert.ok(!fs.existsSync(path.join(home, ".nikxel", "twin", "profile.md")));

  TP.learned = "x\n<!--corrections-->\nVision Tools -> Vizion Tools\n<!--/corrections-->";
  assert.equal(TP.correct("We ship vision tools"), "We ship Vizion Tools");
  assert.equal(TP.correct("Ship Vision Tools"), "Ship Vizion Tools");
  assert.equal(TP.correct("television revision"), "television revision");
  TP.learned = "no region";
  assert.equal(TP.correct("x"), "x");
  TP.learned = "";

  assert.deepEqual(TP.selfLines("[00:00:01] Me: hello there\n[00:00:04] Priya: hi"), ["hello there"]);
  assert.deepEqual(TP.selfLines("[00:00:01] Priya: hi\n[00:00:03] Others: yo"), []);

  fs.mkdirSync(path.join(home, ".nikxel"), { recursive: true });
  fs.writeFileSync(path.join(home, ".nikxel", "wa_sent.jsonl"),
    '{"t":1,"text":"one"}\n{"t":2,"text":"two"}\n{"t":3,"text":"three"}\n');
  assert.deepEqual(TP.recentSentMessages(2), ["three", "two"]);
});

test("TwinDistiller: accept, mergePrompt, distill", async t => {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), "nikxel-twin-"));
  process.env.HOME = home; process.env.USERPROFILE = home;
  let TP: any, TD: any;
  try {
    TP = require("../main/system/twinProfile").TwinProfile;
    TD = require("../main/system/twinDistiller").TwinDistiller;
  } catch (e) { t.skip(`twinDistiller not loadable yet (${(e as Error).message.split("\n")[0]})`); return; }

  assert.equal(TD.accept("  \n ", "KEEP"), "KEEP");
  assert.ok(TD.accept("a".repeat(5000), "x", 3000).length <= 3000);
  assert.equal(TD.accept("line one\nline two", "x", 12), "line one");
  const mp: string = TD.mergePrompt("CUR", ["m1"], ["s1"], "D1");
  for (const s of ["CUR", "m1", "s1", "D1", "<!--corrections-->", "Voice & style", "wrong -> right"]) assert.ok(mp.includes(s), s);

  TP.learned = "OLD";
  const calls: number[] = [];
  await TD.distill([], [], "", async () => { calls.push(1); return "X"; });
  assert.equal(calls.length, 0); assert.equal(TP.learned, "OLD");
  await TD.distill([], [], "did stuff", async (_p: string, kind: string) => { calls.push(1); return kind === "twin-distill" ? "NEW PROFILE" : "BAD"; });
  assert.equal(calls.length, 1); assert.equal(TP.learned, "NEW PROFILE");
  await TD.distill(["hi"], [], "", async () => { throw new Error("boom"); });
  assert.equal(TP.learned, "NEW PROFILE");
  TP.learned = "";
});
