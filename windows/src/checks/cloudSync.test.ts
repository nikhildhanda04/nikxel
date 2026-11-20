// Port of check_cloud_sync.swift: day parser, stable id, no-token no-op, pair stores token, pushDay body.
import { test } from "node:test";
import * as assert from "node:assert/strict";
import * as fs from "fs";
import * as os from "os";
import * as path from "path";

test("CloudSync: dayItems, stable id, no-token no-op, pair, pushDay body", async () => {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), "nikxel-cs-"));
  process.env.HOME = home; process.env.USERPROFILE = home; // before paths.ts reads os.homedir()
  // eslint-disable-next-line @typescript-eslint/no-var-requires
  const CS = require("../main/system/cloudSync").CloudSync;

  const md = "## Summary\nBig day on the dashboard.\n\n## What you worked on\n- [coding] **Fixed typing lag** — 1h 30m\n  - found the missing tap re-enable\n- Planning Q4 ~2h\n\n## Meetings\n- 10:30 — Standup 15m\n- None today.\n\n## WhatsApp\n- No calls today.\n- Ravi asked you to send the deck — open\n\n## Open tasks\n- Send deck — for Ravi — open";
  const { headline, items } = CS.dayItems(md);
  assert.equal(headline, "Big day on the dashboard.");
  assert.equal(items.length, 3); // work + meetings only
  assert.deepEqual({ ...items[0], id: "" }, { id: "", section: "what you worked on", what: "Fixed typing lag", type: "coding", minutes: 90, details: ["found the missing tap re-enable"] });
  assert.deepEqual([items[1].type, items[1].minutes], ["other", 120]);
  assert.equal(items.find((i: any) => i.section === "meetings").type, "meeting");
  assert.ok(!items.some((i: any) => ["whatsapp", "open tasks"].includes(i.section)), "chats and open tasks never sent");
  assert.deepEqual(CS.dayItems(md).items, items);
  assert.equal(items[0].id.length, 12);
  assert.equal(CS.itemID("a", "X"), CS.itemID("a", "x"));
  assert.notEqual(CS.itemID("a", "x"), CS.itemID("b", "x"));

  const w = CS.dayItems("## Summary\nLine one\nline two.\n\nignored\n\n## What you worked on\n- [gaming] Played chess");
  assert.equal(w.headline, "Line one line two.");
  assert.deepEqual([w.items[0].what, w.items[0].type], ["Played chess", "other"]);

  let calls = 0;
  assert.equal(await CS.pushDay(md, "2026-11-20", new Set(), async () => { calls++; return null; }), false);
  assert.equal(calls, 0); // no token: no-op

  assert.equal(await CS.pair("123456", async () => null), false);
  const ok = await CS.pair("123456", async (p: string, b: any) =>
    p === "/api/pair" && b.code === "123456" ? { deviceToken: "tok123" } : null);
  assert.equal(ok, true);
  assert.equal(CS.token(), "tok123");

  let sent: any, bearer: any;
  const r = await CS.pushDay(md, "2026-11-20", new Set([items[0].id]), async (_p: string, b: any, t: any) => { sent = b; bearer = t; return {}; });
  assert.equal(r, true);
  assert.equal(bearer, "tok123");
  assert.deepEqual(Object.keys(sent).sort(), ["date", "headline", "items", "kind"]);
  assert.equal(sent.kind, "day");
  assert.equal(sent.items.length, 2);
  assert.ok(!sent.items.some((i: any) => i.id === items[0].id));
  assert.deepEqual(Object.keys(sent.items[0]).sort(), ["details", "id", "minutes", "section", "type", "what"]);
  assert.equal(await CS.pushDay(md, "2026-11-20", new Set(), async () => null), false);
  const all = new Set(items.map((i: any) => i.id));
  assert.equal(await CS.pushDay(md, "d", all, async () => ({})), false, "all skipped, never sent");
  let e: any, h: any;
  assert.equal(await CS.pushDay(md, "d", all, async (_p: string, b: any) => { e = b; return {}; }, true), true);
  assert.deepEqual(e.items, []);
  await CS.pushDay(md, "d", new Set(["headline"]), async (_p: string, b: any) => { h = b; return {}; });
  assert.equal(h.headline, "");
  assert.equal(h.items.length, 3);
});
