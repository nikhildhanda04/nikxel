// Checks the ERP pure helpers: short-title trimming, assignee name matching,
// and pulling the right Agent-Prompt brief for an action item.
import { test } from "node:test";
import * as assert from "node:assert/strict";
import * as os from "node:os";
import * as fs from "node:fs";
import * as path from "node:path";
import { shortTitle, matchUser, briefFromAgentPrompts, taskDescription } from "../main/system/erp";
import { richHtml } from "../main/recording/markdown";

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

test("taskDescription gives the item hierarchy, bullets and escaping", () => {
  const html = taskDescription("Update the ERP fields; then do the one-time setup", "Meeting on 2026-11-18 <ok>");
  assert.match(html, /<p><strong>What to do<\/strong><\/p>/);
  assert.match(html, /<ul>\s*<li>Update the ERP fields<\/li>\s*<li>then do the one-time setup<\/li>/); // "; " → points
  assert.match(html, /<p><strong>Context<\/strong><\/p>\s*<p>Meeting on 2026-11-18 &lt;ok&gt;<\/p>/);
  assert.doesNotMatch(html, /\*\*/, "no raw markdown leaks through");
});

test("richHtml renders headings, bold, nested lists and inline code", () => {
  const md = [
    "## Current problem",
    "The `/route/` prices are **hard-coded**.",
    "",
    "What's needed:",
    "1. Use the live formula.",
    "  - Sedan row = cheapest sedan.",
    "  - SUV row = cheapest SUV.",
    "2. Round to the nearest ₹10.",
  ].join("\n");
  const html = richHtml(md);
  assert.match(html, /<h3>Current problem<\/h3>/);
  assert.match(html, /<strong>hard-coded<\/strong>/);
  assert.match(html, /<code>\/route\/<\/code>/);
  assert.match(html, /<ol>\s*<li>Use the live formula\.<\/li>\s*<ul>\s*<li>Sedan row = cheapest sedan\.<\/li>/); // nested
  assert.match(html, /<p><strong>What's needed:<\/strong><\/p>/, "a bare 'label:' line is bolded as a run-in heading");
  assert.doesNotMatch(html, /<p><strong>The /, "a normal sentence is not bolded");
  assert.doesNotMatch(html, /\*\*|<br>/, "no flattening, no raw markers");
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
