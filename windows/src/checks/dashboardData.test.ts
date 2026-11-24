// Checks DashboardData: action items are numbered like the page's checkboxes,
// ticks land on the right line, attendees leave out the user and "Others",
// search needs every word, and bot replies come newest first.
import { test } from "node:test";
import * as assert from "node:assert/strict";
import * as fs from "fs";
import * as os from "os";
import * as path from "path";
import * as DashboardData from "../main/system/dashboardData";

const md = `# Meeting — 2026-11-24 21:33

## Attendees
- Nikhil (Me): developer
- **Ali Rajeh** — client
- Others (1 or more participants)

## Action Items
**Can start now**
- [ ] **Reshare the WIC documents** — Owner: Ali Rajeh — Due: Not specified
- [x] **Post the loyalty bug** — Owner: Ali Rajeh — Due: 28 Nov
- [ ] None

**Blocked**
- [ ] **Start WIC testing** (blocked: waiting for docs) — Owner: Nikhil (Me) — Due: Friday

## Open Questions
- [ ] not an action item`;

test("action items, ticks and attendees", () => {
  const items = DashboardData.actionItems(md);
  assert.equal(items.length, 3, "three action items, None and other sections skipped");
  assert.deepEqual(items.map(i => i.n), [1, 2, 3], "numbered like the page's checkboxes");
  assert.deepEqual(items[0], { n: 1, done: false, text: "Reshare the WIC documents", owner: "Ali Rajeh", due: "" }, "text unbolded, unset due is empty");
  assert.ok(items[1].done && items[1].due === "28 Nov", "ticked item and its due");
  assert.ok(items[2].owner === "Nikhil (Me)" && DashboardData.isMe(items[2].owner), "my item");
  const marked = DashboardData.markItem(md, 3, true) ?? "";
  assert.ok(DashboardData.actionItems(marked)[2].done && !DashboardData.actionItems(marked)[0].done, "tick the third, only the third");
  assert.ok(marked.includes("- [ ] not an action item"), "other sections untouched");
  assert.equal(DashboardData.markItem(md, 9, true), null, "no such item");
  assert.deepEqual(DashboardData.attendees(md), ["Ali Rajeh"], "attendees without me or others");
  assert.equal(DashboardData.person("Piyush *(likely)*"), "Piyush");
  assert.equal(DashboardData.person("Speaker 2"), null);
  assert.equal(DashboardData.person("Nikhil's side"), null);
});

test("search, bot replies, tasks and people", () => {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "dd-"));
  const a = path.join(tmp, "a.md"), b = path.join(tmp, "b.md");
  fs.writeFileSync(a, md);
  fs.writeFileSync(b, "# Other\n- lunch with Priya");
  const found = DashboardData.search("wic docs", [{ id: "A", md: a }, { id: "B", md: b }]);
  assert.ok(found.length === 1 && found[0].id === "A", "every word must appear");
  assert.ok(found[0]?.match.includes("WIC"), `match is a readable line (got ${found[0]?.match})`);
  fs.writeFileSync(path.join(tmp, "bot-2026-11-24.jsonl"), `{"t":1,"name":"Ali","text":"hi"}\n{"t":2,"name":"Priya","text":"later"}`);
  const replies = DashboardData.botReplies(new Date(2026, 10, 24), tmp);
  assert.deepEqual(replies.map(r => r.name), ["Priya", "Ali"], "bot replies newest first");

  const { tasks, people } = DashboardData.tasksAndPeople([{ kind: "meetings", title: "M", date: "2026-11-24 21:33", snippet: "", file: path.join(tmp, "a.html") }]);
  assert.equal(tasks.length, 3);
  assert.equal(tasks[0].md, a);
  assert.deepEqual(people.map(p => p.name), ["Ali Rajeh"]);
  assert.equal(people[0].theirs.length, 1, "Ali's open item");
  assert.equal(people[0].mine.length, 1, "my open item, listed under Ali");
  fs.rmSync(tmp, { recursive: true });
});
