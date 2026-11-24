// Checks NoteName: names are cleaned, and saving one renames every file of
// the summary (and its edit history) while leaving other summaries alone.
import { test } from "node:test";
import * as assert from "node:assert/strict";
import * as fs from "fs";
import * as os from "os";
import * as path from "path";
import * as NoteName from "../main/system/noteName";

test("clean", () => {
  assert.equal(NoteName.clean("\"Q3 Budget: Review/Plan\"\nextra"), "Q3 Budget ReviewPlan");
  assert.equal(NoteName.clean("  ..hidden  "), "hidden");
  assert.equal(NoteName.clean("a".repeat(90)).length, 60);
  assert.equal(NoteName.stamp("Acme Kickoff 2026-11-24-153012"), "2026-11-24-153012");
  assert.ok(NoteName.isUnnamed("2026-11-24-153012") && !NoteName.isUnnamed("2026-11-24-153012 Foo"));
});

test("rename moves every sibling once", () => {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "nn-")), dir = path.join(tmp, "meetings"), edits = path.join(tmp, "edits");
  fs.mkdirSync(dir); fs.mkdirSync(path.join(edits, "2026-11-24-153012"), { recursive: true });
  for (const f of ["2026-11-24-153012.md", "2026-11-24-153012.html", "2026-11-24-153012.transcript.txt", "2026-11-24-160000.md"]) {
    fs.writeFileSync(path.join(dir, f), "x");
  }
  const page = NoteName.rename(path.join(dir, "2026-11-24-153012.html"), "Acme Kickoff", edits);
  assert.equal(path.basename(page), "Acme Kickoff 2026-11-24-153012.html");
  assert.deepEqual(fs.readdirSync(dir).sort(), ["2026-11-24-160000.md", "Acme Kickoff 2026-11-24-153012.html", "Acme Kickoff 2026-11-24-153012.md",
    "Acme Kickoff 2026-11-24-153012.transcript.txt"]);
  assert.ok(fs.existsSync(path.join(edits, "Acme Kickoff 2026-11-24-153012")));
  assert.throws(() => NoteName.rename(page, "Again", edits));
  assert.throws(() => NoteName.rename(path.join(dir, "2026-11-24-160000.md"), "!!", edits));
  fs.rmSync(tmp, { recursive: true });
});
