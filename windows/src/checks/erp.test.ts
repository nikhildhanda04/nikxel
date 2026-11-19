// Checks the ERP pure helpers: short-title trimming, assignee name matching,
// and pulling the right Agent-Prompt brief for an action item.
import { test } from "node:test";
import * as assert from "node:assert/strict";
import * as os from "node:os";
import * as fs from "node:fs";
import * as path from "node:path";
import { shortTitle, matchUser, briefFromAgentPrompts, taskDescription } from "../main/system/erp";

test("shortTitle takes the first clause and caps the length", () => {
  assert.equal(shortTitle("Send Priya the pricing sheet; then confirm"), "Send Priya the pricing sheet");
  assert.equal(shortTitle("Short one"), "Short one");
  const long = "Find a workaround for the twenty cloned computers whose old app connects to the original instance and data";
  const out = shortTitle(long);
  assert.ok(out.length <= 71 && out.endsWith("…"));
});

test("matchUser matches exact, then first name, then a unique email local part", () => {
  const users = [
    { id: 1, name: "Kirti Ramtani", email: "kirti@forklyft.in" },
    { id: 2, name: "Nikhil", email: "nikhildhanda84@gmail.com" },
    { id: 3, name: "Prince", email: "prince.1978@gmail.com" },
  ];
  assert.equal(matchUser("Kirti", users)?.id, 1);     // first name
  assert.equal(matchUser("Nikhil (Me)", users)?.id, 2); // "(Me)" stripped
  assert.equal(matchUser("nobody", users), null);
});

test("taskDescription wraps item and context as paragraphs and escapes HTML", () => {
  const html = taskDescription("Fix <bug> & ship", "Meeting on 2026-11-18");
  assert.equal(html, "<p>Fix &lt;bug&gt; &amp; ship</p><p>Meeting on 2026-11-18</p>");
});

test("briefFromAgentPrompts returns the matching fenced brief", () => {
  const md = [
    "## Action Items",
    "- [ ] **Fix the cloned app installs** — Owner: Nikhil — Due: Not specified",
    "",
    "## Agent Prompts",
    "### Fix cloned old app installs connecting to the original instance — Nikhil",
    "```",
    "Find out why cloned app installs connect to the original instance.",
    "",
    "Background: twenty cloned machines reuse the saved instance.",
    "```",
    "",
    "## Decisions",
    "- None.",
  ].join("\n");
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "erp-"));
  const p = path.join(dir, "m.md");
  fs.writeFileSync(p, md);
  const brief = briefFromAgentPrompts("Fix a workaround for the cloned app installs connecting to the original instance", p);
  assert.ok(brief && brief.includes("Find out why cloned app installs"));
  assert.ok(brief!.startsWith("<p>") && brief!.includes("<p>Background:")); // blank lines → separate paragraphs
  // An unrelated item shouldn't match.
  assert.equal(briefFromAgentPrompts("Buy snacks for the office party", p), null);
  fs.rmSync(dir, { recursive: true, force: true });
});
