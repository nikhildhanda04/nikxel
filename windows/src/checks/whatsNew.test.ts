// Checks WHATSNEW.md parsing and which updates are unseen. Mirrors checks/check_whats_new.swift.
import { test } from "node:test";
import * as assert from "node:assert/strict";
import * as fs from "node:fs";
import * as path from "node:path";
import { parse, unseen } from "../main/system/whatsNew";

const md = `# What's new
Intro text, ignored.
<!--
## not a release
-->
## 2026-11-26
### Org
Your team's side.
Second line.

New paragraph.
tour: org-home | Your organization | The overview.
tour: org-chart
### A fix
Renaming finishes.
## 2026-11-25
### Window
tour: home
Everything here.`;

test("parse reads updates, changes, paragraphs and tour steps", () => {
  const r = parse(md);
  assert.deepEqual(r.map(x => x.id), ["2026-11-26", "2026-11-25"]);
  assert.equal(r[0].items[0].body, "Your team's side. Second line.\n\nNew paragraph.");
  assert.deepEqual(r[0].items[0].tour, [
    { section: "org-home", title: "Your organization", text: "The overview." },
    { section: "org-chart", title: "Org", text: r[0].items[0].body },
  ]);
  assert.deepEqual(r[0].items[1].tour, []);
  assert.equal(r[1].items[0].body, "Everything here.");
});

test("unseen: newest only when never seen, else everything above the seen one", () => {
  const r = parse(md);
  assert.deepEqual(unseen(r, undefined), ["2026-11-26"]);
  assert.deepEqual(unseen(r, "2026-11-25"), ["2026-11-26"]);
  assert.deepEqual(unseen(r, "2026-11-26"), []);
  const day = [{ id: "2026-11-27.2", items: [] }, { id: "2026-11-27", items: [] }, { id: "2026-11-26", items: [] }];
  assert.deepEqual(unseen(day, undefined), ["2026-11-27.2", "2026-11-27"], "never seen: all of the newest day");
  assert.deepEqual(unseen(r, "gone"), ["2026-11-26", "2026-11-25"]);
});

test("WHATSNEW.md tours only name real sections", () => {
  const real = parse(fs.readFileSync(path.join(__dirname, "..", "..", "..", "WHATSNEW.md"), "utf8"));
  const ok = new Set(["home", "chat", "library", "tasks", "automations", "people", "activity", "whatsnew", "you", "meetings", "whatsapp",
    "connections", "advanced", "org-home", "org-chart", "org-projects", "org-roles", "org-shared", "org-connection", "meeting"]);
  assert.ok(real.length > 0);
  assert.deepEqual(real.flatMap(r => r.items).flatMap(i => i.tour).filter(s => !ok.has(s.section)), []);
});
