// Checks the "Page (.html)" note and the restyled export HTML: a real-shaped
// meeting note renders, fields become chips, the title becomes an eyebrow,
// and HTML in the Markdown can't get out.
import { test } from "node:test";
import * as assert from "node:assert/strict";
import { NotePage } from "../main/recording/notePage";
import { isNone, markdownToHtml, splitFields } from "../main/recording/markdown";

const note = `# Meeting — 2026-11-12 13:21

## Summary
**Billing moves to Stripe by Friday.**
We walked through the migration and who owns what.

## Action Items
- [ ] **Port the invoice job** — Owner: Vikas — Due: 2026-11-14
- [x] Write the rollback plan — Owner: Unassigned — Due: Not specified

## Decisions
- Ship behind a flag.

## Blockers & Risks
- None.

## Open Questions
- None.

## Follow-Up Meetings
- **Billing check-in** — When: 2026-11-19 10:00 — Duration: 30 min — With: Vikas, Priya

## Speakers
- **Vikas (Me)** — leads billing

## Per-Speaker Highlights
**Vikas:** Wants the flag on by default.

## Agent Prompts
### Port the job
\`\`\`
Move invoice_job.rb to the Stripe client.
\`\`\`
`;

test("a meeting note renders as a page", () => {
  const html = NotePage.html(note);
  assert.match(html, /^<!doctype html>/);
  assert.match(html, /<p class="eyebrow"><span>Minutes of meeting<\/span><span class="when">[^<]*2026[^<]*<\/span>/);
  assert.match(html, /<h1>Billing moves to Stripe by Friday\.<\/h1>/, "bold first Summary line is the headline");
  assert.match(html, /<input type="checkbox" id="task-2" checked>/);
  assert.match(html, /<span class="chip who"><span class="av t\d sm"[^>]*>V<\/span>Vikas<\/span>/);
  assert.match(html, /<span class="chip due">Due /);
  assert.match(html, /<span class="chip unset">Owner Unassigned<\/span>/);
  assert.match(html, /Nothing recorded for Blockers &amp; Risks · Open Questions\./, "None sections collapse");
  assert.match(html, /calendar\.google\.com\/calendar\/render\?action=TEMPLATE[^"]*dates=20261119T100000%2F20261119T103000/);
  assert.match(html, /data:text\/calendar/);
  assert.match(html, /<p class="pn">Vikas \(Me\)<\/p><p class="pr">leads billing<\/p><\/div><\/div>\n<div class="pb"><p>Wants the flag on by default\.<\/p>/);
  assert.match(html, /<pre><code>Move invoice_job\.rb to the Stripe client\.<\/code><\/pre>/);
});

test("export HTML: eyebrow, lead, task chips, None fading", () => {
  const html = markdownToHtml(note);
  assert.match(html, /<p class="eyebrow">Minutes of meeting<\/p>\n<h1>[^<]*12 [^<]*2026<\/h1>\n<p class="meta">/);
  assert.match(html, /<title>Meeting — 2026-11-12 13:21<\/title>/);
  assert.match(html, /<p class="lead"><strong>Billing moves/);
  assert.match(html, /<ul class="tasks">\n<li class="task"><span class="box">☐<\/span>&nbsp; <strong>Port the invoice job<\/strong><br\/><span class="chip owner">&nbsp;<span class="k">Owner<\/span>&nbsp; Vikas&nbsp;<\/span>/);
  assert.match(html, /<span class="chip owner unset">/);
  assert.match(html, /<p class="none">None\.<\/p>/);
  assert.match(html, /<p class="who"><strong>Vikas:<\/strong>/);
  assert.equal((html.match(/<section>/g) ?? []).length, (html.match(/<\/section>/g) ?? []).length);
});

test("field and None helpers", () => {
  assert.deepEqual(splitFields("**Task** — Owner: Vikas — Due: Not specified"),
    { text: "**Task**", fields: [{ key: "Owner", value: "Vikas" }, { key: "Due", value: "Not specified" }] });
  assert.deepEqual(splitFields("Fix a — b: c3 thing — note"), { text: "Fix a — note", fields: [{ key: "b", value: "c3 thing" }] });
  assert.equal(splitFields("Time — 10:30 sharp").fields.length, 0, "a key must be letters");
  assert.ok(isNone("None.") && isNone(" none — nothing came up") && !isNone("Nonetheless"));
});

test("HTML in the Markdown is escaped", () => {
  const evil = `# Meeting — <script>alert(1)</script>

## Action Items
- [ ] <img src=x onerror=alert(1)> — Owner: <b>Eve</b>

## Notes
<script>alert(2)</script>
`;
  for (const html of [NotePage.html(evil), markdownToHtml(evil)]) {
    assert.doesNotMatch(html, /<script>alert|<img|<b>Eve/);
    assert.match(html, /&lt;script&gt;alert\(1\)/);
  }
});
