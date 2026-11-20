// Runnable check for ErpContext — the sealed ERP-facts store, its injected
// block, the reader prompt, and the accept/bound guards. Port of
// check_erp_context.swift. Skips (saying why) if the module isn't loadable yet.
import { test } from "node:test";
import * as assert from "node:assert/strict";
import * as fs from "fs";
import * as os from "os";
import * as path from "path";

test("ErpContext: store, injected block, reader prompt, accept, boundText, ingest", async t => {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), "nikxel-erp-"));
  process.env.HOME = home; process.env.USERPROFILE = home; // before paths.ts reads os.homedir()
  let EC: any;
  try {
    // eslint-disable-next-line @typescript-eslint/no-var-requires
    EC = require("../main/system/erpContext").ErpContext;
  } catch (e) { t.skip(`system/erpContext not loadable yet (${(e as Error).message.split("\n")[0]})`); return; }

  // accept: keeps old on blank / refusal; takes and caps new.
  assert.equal(EC.accept("", "OLD"), "OLD");
  assert.equal(EC.accept("   \n ", "OLD"), "OLD");
  assert.equal(EC.accept("Project Rentop — yours — due Fri", ""), "Project Rentop — yours — due Fri");
  assert.ok(EC.accept("x".repeat(2500), "").length <= 2000);
  assert.equal(EC.accept("Who\nl1\nl2\nl3", "", 8), "Who\nl1"); // over cap: cut on a line boundary
  assert.equal(EC.accept("مشروع رينتوب — مستحق الجمعة", "OLD"), "مشروع رينتوب — مستحق الجمعة"); // non-Latin is real content, not a refusal

  // skipLink: deny logout/delete-style GET links, allow ordinary views (read-only invariant).
  assert.equal(EC.skipLink("https://erp.x.com/web/session/logout"), true);
  assert.equal(EC.skipLink("https://erp.x.com/app?action=delete&id=7"), true);
  assert.equal(EC.skipLink("https://erp.x.com/odoo/contacts"), false);

  // boundText: caps total, joins sections.
  assert.ok(EC.boundText(["a".repeat(5000), "b".repeat(5000)], 8000).length <= 8000);
  assert.ok(EC.boundText(["one", "two"]).includes("one") && EC.boundText(["one", "two"]).includes("two"));

  // readerPrompt carries the captured text and asks for facts only.
  const rp = EC.readerPrompt("CAPTURED ERP TEXT HERE");
  assert.ok(rp.includes("CAPTURED ERP TEXT HERE"));

  // injectedBlock: empty store ⇒ empty block; non-empty ⇒ header + facts.
  EC.facts = "";
  assert.equal(EC.injectedBlock, "");
  EC.facts = "Customer C&N Distributors — active";
  assert.ok(EC.injectedBlock.includes("Customer C&N Distributors"));
  assert.ok(EC.injectedBlock.length > "Customer C&N Distributors — active".length); // has a header line

  // file is 0600 and empty removes it.
  const f = path.join(home, ".nikxel", "twin", "erp.md");
  assert.equal((fs.statSync(f).mode & 0o777), 0o600);
  EC.facts = "";
  assert.ok(!fs.existsSync(f));

  // ingestWith: keeps old facts on empty capture; stores new facts otherwise.
  EC.facts = "OLD FACTS";
  await EC.ingestWith(async () => [], async () => "NEW");
  assert.equal(EC.facts, "OLD FACTS");
  await EC.ingestWith(async () => ["Project Rentop — yours"], async () => "Project Rentop — yours — due Fri");
  assert.ok(EC.facts.includes("Rentop"));

  // userContextBlock puts ERP facts before the user's own context (so the user wins).
  const Settings = require("../main/core/settings").Settings;
  Settings.userContext = "ZZUSER"; EC.facts = "AAERP";
  const b: string = Settings.userContextBlock;
  assert.ok(b.indexOf("AAERP") >= 0 && b.indexOf("AAERP") < b.indexOf("ZZUSER"));
  EC.facts = "";

  fs.rmSync(home, { recursive: true, force: true });
});
