// Checks GoogleSync's parsing of a generated MOM. Pure string/date work -- no
// network, nothing written to anyone's Google account. Port of
// check_google_sync.swift.
import { test } from "node:test";
import * as assert from "node:assert/strict";
import { GoogleSync } from "../main/google/googleSync";

const tz = "Asia/Kolkata";

/// "yyyy-MM-dd HH:mm" in Asia/Kolkata (UTC+05:30, no DST).
function day(s: string): Date {
  const m = /^(\d{4})-(\d{2})-(\d{2}) (\d{2}):(\d{2})$/.exec(s)!;
  return new Date(Date.UTC(+m[1], +m[2] - 1, +m[3], +m[4], +m[5]) - 330 * 60_000);
}

const note = `# Meeting — 2026-11-09 10:00

## Summary
We talked about the billing migration.

## Decisions
- Ship behind a flag.

## Action Items
- [ ] **Send Priya the updated pricing sheet** — Owner: Rohan — Due: 2026-11-12
- [ ] **Rewrite the retry logic — not the docs — before the demo** — Owner: Me — Due: Not specified
- [ ] **Chase legal on the DPA** — Owner: Unassigned — Due: 2026-11-20
- [x] **Already done thing** — Owner: Priya — Due: Not specified
- [ ] **Book the big room** — Owner: Priya — Due: next Friday

## Follow-Up Meetings
- **Design review** — When: 2026-11-12 15:30 — Duration: 45 min — With: Priya, Rohan
- **Legal sync** — When: Not specified — Duration: 30 min — With: Meera
- **Thursday afternoon catch-up** — When: 2026-11-13 — Duration: 60 min — With: Not specified

## Agent Prompts
### Retry logic — Me
\`\`\`
Add retry handling.
\`\`\``;

test("action items", () => {
  const items = GoogleSync.parseActionItems(note, tz);
  assert.equal(items.length, 5, `expected 5 action items, got ${items.length}`);

  assert.equal(items[0].title, "Send Priya the updated pricing sheet");
  assert.equal(items[0].owner, "Rohan");
  assert.deepEqual(items[0].due, day("2026-11-12 00:00"));

  // An em dash inside the task must not split the title: fields are
  // sliced from the right, which is the whole reason for that choice.
  assert.equal(items[1].title, "Rewrite the retry logic — not the docs — before the demo");
  assert.equal(items[1].owner, "Me");
  assert.equal(items[1].due, null, "\"Not specified\" must not become a date");

  // "Unassigned" is normalised away so the task doesn't get prefixed.
  assert.equal(items[2].owner, "", "Unassigned should read as no owner");
  assert.deepEqual(items[2].due, day("2026-11-20 00:00"));

  // A ticked box is still an item -- the model sometimes marks one done.
  assert.equal(items[3].title, "Already done thing");

  // Prose dates are dropped, never guessed at.
  assert.equal(items[4].due, null, "\"next Friday\" must not be invented into a date");
});

test("task titles", () => {
  const items = GoogleSync.parseActionItems(note, tz);
  assert.equal(items[0].taskTitle("Jake"), "[Rohan] Send Priya the updated pricing sheet");
  assert.equal(items[1].taskTitle("Jake"), "Rewrite the retry logic — not the docs — before the demo",
    "a task owned by \"Me\" is mine, no prefix");
  assert.equal(items[2].taskTitle("Jake"), "Chase legal on the DPA", "unassigned gets no prefix");
  assert.equal(items[0].taskTitle("Rohan"), "Send Priya the updated pricing sheet",
    "matching the user's own name means no prefix");

  // The Speakers section labels the user "Jake (Me)", so that is the
  // owner string that really arrives -- it must read as the user's own
  // task, not get prefixed with their own name.
  const labelled = GoogleSync.parseActionItems(
    "## Action Items\n- [ ] **Approve the comp review** — Owner: Jake (Me) — Due: Not specified", tz);
  assert.equal(labelled.length, 1);
  assert.equal(labelled[0].normalizedOwner, "Jake");
  assert.ok(labelled[0].isMine("Jake"));
  assert.equal(labelled[0].taskTitle("Jake"), "Approve the comp review");
  assert.equal(labelled[0].taskTitle("Anjali"), "[Jake] Approve the comp review",
    "somebody else's task keeps the name, without the (Me) marker");

  // A trailing note after the Due field must not become a due date.
  const trailing = GoogleSync.parseActionItems(
    "## Action Items\n- [ ] **Ship the guard** — Owner: Unassigned — Due: Not specified — *Waiting on the ticket.*", tz);
  assert.ok(trailing.length === 1 && trailing[0].due === null, "trailing prose must not parse as a date");
});

test("follow-ups", () => {
  const ups = GoogleSync.parseFollowUps(note, tz);
  assert.equal(ups.length, 1, `only the one with a real date AND time, got ${ups.length}: ${ups.map(u => u.title)}`);
  assert.equal(ups[0].title, "Design review");
  assert.deepEqual(ups[0].start, day("2026-11-12 15:30"));
  assert.equal(ups[0].durationMin, 45);
  assert.equal(ups[0].with, "Priya, Rohan");
});

test("\"None\" placeholders are not items", () => {
  const empty = `## Action Items
- [ ] None — no tasks came out of this meeting.

## Follow-Up Meetings
- None.`;
  assert.equal(GoogleSync.parseActionItems(empty, tz).length, 0, "\"None\" is not a task");
  assert.equal(GoogleSync.parseFollowUps(empty, tz).length, 0, "\"None\" is not a meeting");
});

test("a note with the sections removed (custom summary style)", () => {
  const stripped = `# Meeting — 2026-11-09 10:00

## Summary
Short one.`;
  assert.equal(GoogleSync.parseActionItems(stripped, tz).length, 0);
  assert.equal(GoogleSync.parseFollowUps(stripped, tz).length, 0);
  assert.equal(GoogleSync.section(stripped, "Action Items"), "",
    "a missing section reads as empty, not as the whole document");
});

test("section slicing stops at the next ##", () => {
  const decisions = GoogleSync.section(note, "Decisions");
  assert.ok(decisions.includes("Ship behind a flag"));
  assert.ok(!decisions.includes("Send Priya"), "a section must not bleed into the next one");
  // ### subheadings stay inside their ## section.
  assert.ok(GoogleSync.section(note, "Agent Prompts").includes("### Retry logic"));
});

test("date parsers in isolation", () => {
  assert.deepEqual(GoogleSync.parseDay("2026-11-12", tz), day("2026-11-12 00:00"));
  assert.deepEqual(GoogleSync.parseDay(" **2026-11-12** ", tz), day("2026-11-12 00:00"),
    "stray bold markers must not defeat the date");
  assert.equal(GoogleSync.parseDay("Not specified", tz), null);
  assert.equal(GoogleSync.parseDay("12/11/2026", tz), null, "only ISO dates are trusted");
  assert.deepEqual(GoogleSync.parseMoment("2026-11-12 15:30", tz), day("2026-11-12 15:30"));
  assert.deepEqual(GoogleSync.parseMoment("2026-11-12T15:30", tz), day("2026-11-12 15:30"));
  assert.equal(GoogleSync.parseMoment("2026-11-12", tz), null,
    "a date with no time is not a moment -- it must not default to midnight");
});

test("chat task error helpers", () => {
  const msg = "Google Tasks API has not been used in project 123 before or it is disabled. Enable it by visiting https://console.developers.google.com/apis/api/tasks.googleapis.com/overview?project=123 then retry.";
  assert.ok(GoogleSync.isAPIDisabled(msg));
  assert.equal(GoogleSync.consoleURL(msg),
    "https://console.developers.google.com/apis/api/tasks.googleapis.com/overview?project=123");
  assert.equal(GoogleSync.consoleURL("Forbidden"), null);
  assert.match(GoogleSync.jitsiLink(), /^https:\/\/meet\.jit\.si\/Nikxel-[0-9A-F]{16}$/);
});
