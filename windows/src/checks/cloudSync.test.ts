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
  assert.deepEqual({ ...items[0], id: "" }, { id: "", section: "what you worked on", what: "Fixed typing lag", type: "coding", minutes: 90, details: ["found the missing tap re-enable"], project: "" });
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
  const pm = CS.dayItems("## What you worked on\n- [coding] [[Produce POS]] Fixed sign-out 1h\n- [other] No project here\n\n## ERP tasks\n- [[Produce POS]] Sign-out button — In Progress (due 2026-11-25)\n- [[A ]] weird]] name]] Task — Done").items;
  assert.equal(pm.length, 4);
  assert.deepEqual([pm[0].project, pm[0].what, pm[0].minutes, pm[0].type], ["Produce POS", "Fixed sign-out", 60, "coding"]);
  assert.equal(pm[1].project, "");
  assert.deepEqual([pm[2].section, pm[2].type, pm[2].project, pm[2].what], ["erp tasks", "planning", "Produce POS", "Sign-out button — In Progress (due 2026-11-25)"]);
  assert.equal(pm[3].project, "A");

  const est = CS.dayItems("## What you worked on\n- Debugged after the 2h meeting with Ravi (~45m)\n- Wrote report (~1h 20m).\n- Fixed login 30m — Done\n\n## ERP tasks\n- [[Produce POS]] Raise SLA to 2h — In Progress").items;
  assert.equal(est.length, 4);
  assert.deepEqual([est[0].minutes, est[0].what], [45, "Debugged after the 2h meeting with Ravi"]);
  assert.deepEqual([est[1].minutes, est[1].what], [80, "Wrote report."]);
  assert.equal(est[2].minutes, 30);
  assert.deepEqual([est[3].minutes, est[3].what], [0, "Raise SLA to 2h — In Progress"]);

  let calls = 0;
  assert.equal(await CS.pushDay(md, "2026-11-20", new Set(), async () => { calls++; return null; }), false);
  assert.equal(calls, 0); // no token: no-op

  assert.equal(await CS.pair("123456", async () => null), false);
  fs.mkdirSync(path.dirname(CS.projectsFile()), { recursive: true });
  fs.writeFileSync(CS.projectsFile(), '[{"id":"old","name":"Old Org"}]');
  assert.equal(await CS.pair("123456", async () => null), false);
  assert.ok(fs.existsSync(CS.projectsFile()), "failed pair keeps the cache");
  const ok = await CS.pair("123456", async (p: string, b: any) =>
    p === "/api/pair" && b.code === "123456" ? { deviceToken: "tok123" } : null);
  assert.equal(ok, true);
  assert.equal(CS.token(), "tok123");
  assert.ok(!fs.existsSync(CS.projectsFile()), "pair clears the previous project cache");

  let sent: any, bearer: any;
  const r = await CS.pushDay(md, "2026-11-20", new Set([items[0].id]), async (_p: string, b: any, t: any) => { sent = b; bearer = t; return {}; });
  assert.equal(r, true);
  assert.equal(bearer, "tok123");
  assert.deepEqual(Object.keys(sent).sort(), ["date", "headline", "items", "kind"]);
  assert.equal(sent.kind, "day");
  assert.equal(sent.items.length, 2);
  assert.ok(!sent.items.some((i: any) => i.id === items[0].id));
  assert.deepEqual(Object.keys(sent.items[0]).sort(), ["details", "id", "minutes", "project", "section", "type", "what"]);
  assert.equal(await CS.pushDay(md, "2026-11-20", new Set(), async () => null), false);
  const all = new Set(items.map((i: any) => i.id));
  assert.equal(await CS.pushDay(md, "d", all, async () => ({})), false, "all skipped, never sent");
  let e: any, h: any;
  assert.equal(await CS.pushDay(md, "d", all, async (_p: string, b: any) => { e = b; return {}; }, true), true);
  assert.deepEqual(e.items, []);
  await CS.pushDay(md, "d", new Set(["headline"]), async (_p: string, b: any) => { h = b; return {}; });
  assert.equal(h.headline, "");
  assert.equal(h.items.length, 3);

  const mom = "# Meeting — 21 Nov\n\n## Summary\nShipped it.\n\n## Client Summary\nDear client, all good.\n### Next\n- more\n\n## Action Items\n- [ ] Ravi: fix login";
  const sb = CS.meetingShareBody(mom);
  assert.ok(!sb.includes("Client Summary") && !sb.includes("Dear client") && !sb.includes("### Next"), "drops the client summary");
  assert.ok(sb.startsWith("# Meeting") && sb.includes("## Summary\nShipped it.") && sb.includes("## Action Items\n- [ ] Ravi: fix login"), "keeps the rest");
  assert.equal(CS.meetingShareBody("## Client Summary\nonly").trim(), "");
  assert.equal(CS.meetingShareBody("é".repeat(25000)).length, 20000);

  // projects(): token is "tok123" from the pair above.
  assert.deepEqual(await CS.projects(async () => null), [], "no cache, fetch fails");
  let gp: any, gb: any;
  const fresh = await CS.projects(async (p: string, t: any) => { gp = p; gb = t; return [{ id: "p1", name: "Produce POS" }, { id: "p2", name: "Nikxel" }]; });
  assert.deepEqual(fresh, [{ id: "p1", name: "Produce POS" }, { id: "p2", name: "Nikxel" }]);
  assert.deepEqual([gp, gb], ["/api/device/projects", "tok123"]);
  assert.deepEqual(await CS.projects(async () => null), fresh, "fetch fails: cached list");
  let sp: any, sh: any;
  assert.equal(await CS.shareMeeting("p1", "2026-11-21-101500", "Meeting — 21 Nov", "2026-11-21", sb, async (p: string, b: any) => { sp = p; sh = b; return {}; }), true);
  assert.equal(sp, "/api/projects/p1/meetings");
  assert.deepEqual(sh, { meeting_id: "2026-11-21-101500", title: "Meeting — 21 Nov", date: "2026-11-21", body: sb });
  assert.equal(await CS.shareMeeting("p1", "m", "t", "2026-11-21", "b", async () => null), false);
});
