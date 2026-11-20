// Checks the end-of-day page: a real-shaped summary renders with its date,
// headline, number tiles, timeline, meeting times and chat-task statuses,
// empty sections collapse, and HTML in the Markdown can't get out.
import { test } from "node:test";
import * as assert from "node:assert/strict";
import { DayPage } from "../main/system/dayPage";
import { CloudSync } from "../main/system/cloudSync";
import { DayLogger } from "../main/system/dayLogger";

export const day = `# 2026-11-12 — Day in review

## Summary
A Windows day: most of it went into porting Nikxel to Electron. The afternoon was catching the port up with the Mac.

## What you worked on
- Ported the setup wizard and the agent check (asked at ~2pm, shipped commit 731a213).
- Styled summary page for Windows — done

## Meetings
- 10:30 — Standup with Priya: billing moves to Stripe.
- Design review, no time noted.

## WhatsApp
- Missed call from Rahul (~4pm).
- Priya asked you to send the invoice (~11am) — open
- Vikas asked for the build link — done.

## Browsing & Reading
- ~45 min in Chrome, mostly Electron docs.

## Other
- None.
`;

const stats = { codingSeconds: 5 * 3600 + 20 * 60, activeSeconds: 8 * 3600, meetings: 2, messages: 0 };

test("a day renders", () => {
  const html = DayPage.html(day, stats);
  assert.match(html, /<p class="date">[^<]*12[^<]*<\/p>/);
  assert.match(html, /<span class="yr">2026<\/span>/);
  assert.match(html, /<h1>A Windows day: most of it went into porting Nikxel to Electron\.<\/h1>/);
  assert.match(html, /<b>5h 20m<\/b><span>coding<\/span>/);
  assert.match(html, /<b>2<\/b><span>meetings<\/span>/);
  assert.doesNotMatch(html, /<span>messages<\/span>/, "zero tiles are left out");
  assert.match(html, /<ol class="line"><li>Ported the setup wizard/);
  assert.match(html, /<span class="tm">10:30<\/span><div class="mb"><p>Standup with Priya/);
  assert.match(html, /send the invoice \(~11am\) <span class="st open">open<\/span>/);
  assert.match(html, /build link <span class="st done">done<\/span>/);
  assert.match(html, /Windows <span class="st done">done<\/span>/);
  assert.match(html, /class="sec panel"><h2>Browsing &amp; Reading<\/h2>/);
  assert.match(html, /Quiet on Other\./);
});

test("nested bullets stay under their heading", () => {
  const html = DayPage.html(`# 2026-11-12 — Day in review

## What you worked on
- **vitbnotes**
  - Fixed the refresh bug.
    - two files
  - Raised the budgets — done
- **Sarvam backend**

## Meetings
- **00:13**: OnTrack testing.
- **10:31, PAI outbound status**:
  - Connection rate is about 50%.
`);
  assert.match(html, /What you worked on <span class="n">2<\/span>/, "counts top-level items only");
  assert.match(html, /<li><strong>vitbnotes<\/strong><ul class="kids"><li>Fixed the refresh bug\.<ul class="kids"><li>two files<\/li><\/ul><\/li><li>Raised the budgets <span class="st done">done<\/span><\/li><\/ul><\/li>/);
  assert.match(html, /Meetings <span class="n">2<\/span>/);
  assert.match(html, /<span class="tm">00:13<\/span><div class="mb"><p>OnTrack testing\.<\/p>/);
  assert.match(html, /<span class="tm">10:31<\/span><div class="mb"><p><strong>PAI outbound status<\/strong>:<\/p><ul class="kids"><li>Connection rate/);
});

test("no stats, no tiles", () => {
  assert.doesNotMatch(DayPage.html(day), /class="tiles"/);
});

test("HTML in the summary is escaped", () => {
  const html = DayPage.html("# 2026-11-12 — Day in review\n\n## What you worked on\n- <script>alert(1)</script> <img src=x>\n");
  assert.doesNotMatch(html, /<script>alert/);
  assert.doesNotMatch(html, /<img src=x>/);
});

const tagged = "## Summary\nBig day on the dashboard.\n\n## What you worked on\n- [coding] **Fixed typing lag** — 1h 30m\n  - found the missing tap re-enable\n- Planning Q4 ~2h\n\n## Meetings\n- 10:30 — Standup 15m\n- None today.\n\n## WhatsApp\n- No calls today.\n- Ravi asked you to send the deck — open\n\n## Open tasks\n- Send deck — for Ravi — open\n\n## Other\n- [other] Long focus block after lunch\n";

test("daily page: tags hidden, every sent item carries its dayItems id, send bar", () => {
  const html = DayPage.html(tagged, null, false, true);
  assert.doesNotMatch(html, /\[coding\]|\[other\]/);
  assert.match(html, new RegExp(`data-id="${CloudSync.itemID("what you worked on", "Fixed typing lag")}"`));
  const ids = CloudSync.dayItems(tagged).items.map(i => i.id);
  assert.equal(ids.length, 4);
  for (const id of ids) assert.match(html, new RegExp(`data-id="${id}"`));
  assert.match(html, /<h1 data-id="headline">/);
  assert.equal((html.match(/data-id="/g) ?? []).length, ids.length + 1, "none-ish bullets get no id; headline is crossable");
  assert.match(html, /class="nx-send"/);
  assert.match(html, /class="nx-todo"/, "open-task checkbox still renders");
});

test("daily page embeds exactly the day pushDay sends, for the preview", () => {
  const html = DayPage.html(tagged, null, false, true);
  const json = /<script type="application\/json" id="nx-day">(.*?)<\/script>/.exec(html);
  assert.ok(json, "embedded day");
  assert.deepEqual(JSON.parse(json[1]), CloudSync.dayItems(tagged), "same headline and items, tags kept as types");
  assert.match(html, /<dialog class="nx-pv"/);
  assert.match(html, /class="nx-prev"/);
  assert.doesNotMatch(DayPage.html(tagged, null, false, false), /id="nx-day"|<dialog class="nx-pv"/, "not on weekly pages");
});

test("not daily: no ids, no send bar, tags still hidden", () => {
  const html = DayPage.html(tagged, null, false, false);
  assert.doesNotMatch(html, /data-id=/);
  assert.doesNotMatch(html, /class="nx-send"/);
  assert.doesNotMatch(html, /\[coding\]/);
  assert.match(html, /class="nx-todo"/);
});

test("open tasks and chats stay on the page but are never crossable or sent", () => {
  const html = DayPage.html(tagged, null, false, true);
  assert.doesNotMatch(html, new RegExp(`data-id="${CloudSync.itemID("open tasks", "Send deck — for Ravi — open")}"`));
  assert.doesNotMatch(html, new RegExp(`data-id="${CloudSync.itemID("whatsapp", "Ravi asked you to send the deck — open")}"`));
  assert.match(html, /class="nx-todo"/);
  assert.match(DayPage.markTask(tagged, 0, true) ?? "", /Ravi — done/);
});

test("project tags: hidden on the page, carried in the embedded day, pill in the preview", () => {
  const html = DayPage.html("## What you worked on\n- [coding] [[Produce POS]] Fixed sign-out 1h\n\n## ERP tasks\n- [[Produce POS]] Sign-out button — In Progress (due 2026-11-25)\n", null, false, true);
  assert.doesNotMatch(html, /\[\[Produce POS\]\]|\[coding\]/);
  const json = /<script type="application\/json" id="nx-day">(.*?)<\/script>/.exec(html);
  assert.equal(JSON.parse(json![1]).items[0].project, "Produce POS");
  assert.match(html, /pv-proj/);
});

test("erpTasksSection", () => {
  assert.equal(DayLogger.erpTasksSection([{ name: "Sign-out button", project: "Produce POS", stage: "In Progress", deadline: "2026-11-25" }, { name: "X", project: "", stage: "Done", deadline: "" }]),
    "\n## ERP tasks\n- [[Produce POS]] Sign-out button — In Progress (due 2026-11-25)\n- X — Done\n");
  assert.equal(DayLogger.erpTasksSection([]), "");
});
