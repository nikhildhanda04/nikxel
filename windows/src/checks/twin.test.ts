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
  assert.equal(TP.correct("television revision"), "television revision");
  TP.learned = "no region";
  assert.equal(TP.correct("x"), "x");
  TP.learned = "";
});
