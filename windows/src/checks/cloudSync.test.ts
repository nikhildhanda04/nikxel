// Port of check_cloud_sync.swift: pure parser, stable id, no-token no-op, pair stores token.
import { test } from "node:test";
import * as assert from "node:assert/strict";
import * as fs from "fs";
import * as os from "os";
import * as path from "path";

test("CloudSync: workItems, stable id, no-token no-op, pair, push body", async () => {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), "nikxel-cs-"));
  process.env.HOME = home; process.env.USERPROFILE = home; // before paths.ts reads os.homedir()
  // eslint-disable-next-line @typescript-eslint/no-var-requires
  const CS = require("../main/system/cloudSync").CloudSync;

  const md = [
    "# 2026-11-20 — Day in review", "", "## Summary", "- 45m of not-a-work-item here", "",
    "## What you worked on",
    "- **Fixed typing lag** in Nikxel — 1h 30m",
    "- Shipped invoice fix (45m)",
    "- Planning the Q4 roadmap ~2h",
    "  - sub detail 10m",
    "- None today.", "", "## Meetings", "- Standup 15m",
  ].join("\n");
  const items = CS.workItems(md);
  assert.equal(items.length, 3);
  assert.deepEqual([items[0].what, items[0].minutes], ["Fixed typing lag in Nikxel", 90]);
  assert.deepEqual([items[1].what, items[1].minutes], ["Shipped invoice fix", 45]);
  assert.equal(items[2].minutes, 120);
  assert.deepEqual(CS.workItems(md), items);
  assert.equal(items[0].id.length, 12);

  let calls = 0;
  await CS.pushDaily(md, "2026-11-20", async () => { calls++; return null; });
  assert.equal(calls, 0); // no token: no-op

  assert.equal(await CS.pair("123456", async () => null), false);
  const ok = await CS.pair("123456", async (p: string, b: any) =>
    p === "/api/pair" && b.code === "123456" ? { deviceToken: "tok123" } : null);
  assert.equal(ok, true);
  assert.equal(CS.token(), "tok123");

  let sent: any, bearer: any;
  await CS.pushDaily(md, "2026-11-20", async (_p: string, b: any, t: any) => { sent = b; bearer = t; return {}; });
  assert.equal(bearer, "tok123");
  assert.deepEqual(Object.keys(sent).sort(), ["date", "items", "kind"]);
  assert.deepEqual(Object.keys(sent.items[0]).sort(), ["id", "minutes", "what"]);
});
