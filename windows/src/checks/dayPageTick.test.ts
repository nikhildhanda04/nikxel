// Checks DayPage.tick / openTasksIndexed: the index counts only bullets with a
// status (as the page's data-i does), done ones drop out of the list, and a
// tick lands in both the .md and the .html box.
import { test } from "node:test";
import * as assert from "node:assert/strict";
import * as fs from "fs";
import * as os from "os";
import * as path from "path";
import { tick, openTasksIndexed } from "../main/system/dayPage";

const md = "# Day\n\n## Open tasks\n- Reply to **Ali** — open\n- a note without a status\n- Ship build — done\n- Call Priya — open\n\n## Other\n- x — open";

test("openTasksIndexed", () => {
  assert.deepEqual(openTasksIndexed(md), [{ i: 0, text: "Reply to Ali" }, { i: 2, text: "Call Priya" }]);
});

test("tick", () => {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "dp-"));
  const page = path.join(tmp, "2026-11-24.html");
  fs.writeFileSync(path.join(tmp, "2026-11-24.md"), md);
  fs.writeFileSync(page, '<input data-i="0"><input data-i="2" disabled>');
  assert.ok(tick(page, 2, true));
  assert.deepEqual(openTasksIndexed(fs.readFileSync(path.join(tmp, "2026-11-24.md"), "utf8")), [{ i: 0, text: "Reply to Ali" }]);
  assert.equal(fs.readFileSync(page, "utf8"), '<input data-i="0"><input data-i="2" checked disabled>');
  assert.ok(!tick(page, 7, true), "no such task");
  fs.rmSync(tmp, { recursive: true });
});
