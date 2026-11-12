// Checks the summary-template files: seeding, comment stripping, the legacy
// summary_style.txt migration, naming, reset and delete. Port of
// check_summary_templates.swift. Unlike the Mac check, this runs against a
// throwaway home (node --test gives each file its own process), so the
// user's real ~/.nikxel is never touched.
import { test } from "node:test";
import * as assert from "node:assert/strict";
import * as fs from "fs";
import * as os from "os";
import * as path from "path";

const home = fs.mkdtempSync(path.join(os.tmpdir(), "nikxel-templates-"));
process.env.HOME = process.env.USERPROFILE = home;
// Required after HOME is set: paths.ts resolves ~/.nikxel at load.
// eslint-disable-next-line @typescript-eslint/no-var-requires
const { SummaryTemplates } = require("../main/recording/summaryTemplates") as typeof import("../main/recording/summaryTemplates");
// eslint-disable-next-line @typescript-eslint/no-var-requires
const { Settings } = require("../main/core/settings") as typeof import("../main/core/settings");

test.after(() => fs.rmSync(home, { recursive: true, force: true }));

test("summary templates", () => {
  assert.ok(SummaryTemplates.templatesDir.startsWith(home), "must run in the throwaway home");
  const legacy = path.join(home, ".nikxel", "summary_style.txt");

  // --- Seeding -----------------------------------------------------
  SummaryTemplates.seedIfMissing();
  for (const t of SummaryTemplates.shipped) assert.ok(SummaryTemplates.exists(t.slug), `${t.slug} was not seeded`);

  // Default must contribute nothing: it is all comments, so picking it
  // leaves the shipped prompt untouched.
  assert.equal(SummaryTemplates.instructions("default"), "", "Default must add nothing to the prompt");
  Settings.summaryTemplate = "default";
  assert.equal(SummaryTemplates.summaryStyleInstruction, "", "Default must produce no HOUSE STYLE block");

  for (const slug of ["developer", "project-manager", "hr", "co-founder"]) {
    const text = SummaryTemplates.instructions(slug);
    assert.ok(text, `${slug} has no instructions`);
    // Instructions legitimately name sections, so no LINE may start with #.
    assert.ok(!text.split("\n").some(l => l.trim().startsWith("#")), `${slug} leaked a comment line into the prompt`);
    Settings.summaryTemplate = slug;
    const instr = SummaryTemplates.summaryStyleInstruction;
    assert.ok(instr.includes("HOUSE STYLE"), `${slug} produced no HOUSE STYLE block`);
    assert.ok(instr.includes(text), `${slug}'s instructions did not reach the prompt`);
    assert.ok(instr.includes("Never invent content"), `${slug} lost the no-invention guard`);
    assert.ok(instr.includes("## Action Items"), `${slug} lost the Google-heading guard`);
  }

  const dev = SummaryTemplates.instructions("developer");
  const hr = SummaryTemplates.instructions("hr");
  assert.notEqual(dev, hr);
  assert.ok(dev.includes("Agent Prompts") && hr.includes("Drop the Agent Prompts"), "developer keeps agent prompts, HR drops them");

  // --- Seeding is never destructive ---------------------------------
  fs.writeFileSync(SummaryTemplates.url("developer"), "My own edit.");
  SummaryTemplates.seedIfMissing();
  assert.equal(SummaryTemplates.instructions("developer"), "My own edit.", "seeding overwrote an edited template");

  // --- Reset puts a shipped one back --------------------------------
  assert.ok(SummaryTemplates.reset("developer"));
  assert.equal(SummaryTemplates.instructions("developer"), dev, "reset did not restore");
  assert.ok(!SummaryTemplates.reset("nope-not-shipped"), "reset must refuse unknown slugs");

  // --- Naming --------------------------------------------------------
  assert.equal(SummaryTemplates.slugify("Client Calls"), "client-calls");
  assert.equal(SummaryTemplates.slugify("  Board / Investor  "), "board-investor");
  assert.equal(SummaryTemplates.slugify("1:1s"), "11s");
  assert.equal(SummaryTemplates.slugify("!!!"), "", "a name with nothing usable must slug to empty");
  assert.equal(SummaryTemplates.displayName("client-calls"), "Client Calls");
  assert.equal(SummaryTemplates.displayName("hr"), "HR", "shipped names win over derivation");
  assert.equal(SummaryTemplates.displayName("qa"), "QA", "short slugs read as acronyms");
  assert.equal(SummaryTemplates.displayName("project-manager"), "Project Manager");

  // --- Create / copy / delete -----------------------------------------
  assert.equal(SummaryTemplates.create("Check Scratch"), "check-scratch");
  assert.equal(SummaryTemplates.instructions("check-scratch"), "", "a blank new template is all comments");
  assert.equal(SummaryTemplates.create("Check Scratch"), null, "duplicate names must be refused");
  assert.equal(SummaryTemplates.create("   "), null, "an empty name must be refused");
  assert.equal(SummaryTemplates.create("Check Copy", "hr"), "check-copy");
  assert.equal(SummaryTemplates.instructions("check-copy"), hr, "copying must carry the source's instructions, not its comments");

  // Listing: shipped first in order, then user templates alphabetically.
  const slugs = SummaryTemplates.available().map(t => t.slug);
  assert.deepEqual(slugs.slice(0, 5), SummaryTemplates.shipped.map(t => t.slug), `shipped order wrong: ${slugs}`);
  assert.ok(slugs.indexOf("check-copy") >= 0 && slugs.indexOf("check-copy") < slugs.indexOf("check-scratch"),
    "user templates should be alphabetical");
  assert.ok(!SummaryTemplates.isShipped("check-copy") && SummaryTemplates.isShipped("hr"));

  // Deleting the active template falls back to Default.
  Settings.summaryTemplate = "check-copy";
  SummaryTemplates.delete("check-copy");
  assert.ok(!SummaryTemplates.exists("check-copy"));
  assert.equal(Settings.summaryTemplate, "default", "deleting the active template must fall back to Default");
  SummaryTemplates.delete("check-scratch");

  // --- Legacy summary_style.txt migration ------------------------------
  // All-comment legacy file: nothing was ever written, so just retire it.
  fs.writeFileSync(legacy, "# just the template\n# nothing written");
  SummaryTemplates.seedIfMissing();
  assert.ok(!fs.existsSync(legacy), "an empty legacy file should be removed");
  assert.ok(!SummaryTemplates.exists("my-style"), "an empty legacy file should not become a template");

  // A legacy file with real content becomes "My Style" and is selected.
  fs.writeFileSync(legacy, "# header\nKeep it to three sentences.");
  SummaryTemplates.seedIfMissing();
  assert.ok(!fs.existsSync(legacy), "the legacy file should be removed after migrating");
  assert.equal(SummaryTemplates.instructions("my-style"), "Keep it to three sentences.");
  assert.equal(Settings.summaryTemplate, "my-style", "the migrated template must be the selected one");
});
