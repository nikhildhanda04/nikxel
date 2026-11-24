// Checks SummaryLibrary: one entry per summary (client/transcript/sent files
// skipped), titles from the stem's name, the md heading or the html <title>,
// dates from the stamp, newest first.
import { test } from "node:test";
import * as assert from "node:assert/strict";
import * as fs from "fs";
import * as os from "os";
import * as path from "path";
import * as SummaryLibrary from "../main/system/summaryLibrary";

test("scan", () => {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "sl-"));
  const files: Record<string, string> = {
    "meetings/2026-11-24-153012.md": "# Meeting — 2026-11-24 15:30\n\n## Summary\n- **Agreed** the Q3 plan.\n",
    "meetings/2026-11-24-153012.html": "<title>x</title>",
    "meetings/2026-11-24-153012.client.html": "",
    "meetings/2026-11-24-153012.transcript.txt": "",
    "meetings/Acme Kickoff 2026-11-25-090000.md": "# Meeting — 2026-11-25 09:00\n",
    "meetings/Acme Kickoff 2026-11-25-090000.html": "",
    "meetings/sample.html": "<html><title>Sample page</title>",
    "notes/2026-11-20-101010.md": "# Lecture notes\n",
    "daily/2026-11-23.md": "# 2026-11-23 — Day in review\n",
    "daily/2026-11-23.html": "",
    "daily/2026-11-23.sent.json": "{}",
    "weekly/2026-11-22.md": "# Week\n",
  };
  for (const [p, body] of Object.entries(files)) {
    const f = path.join(tmp, p);
    fs.mkdirSync(path.dirname(f), { recursive: true });
    fs.writeFileSync(f, body);
  }
  const all = SummaryLibrary.scan(tmp);
  const byName = new Map(all.map(e => [path.basename(e.file), e]));

  assert.equal(all.length, 6, "one entry per summary, client/transcript/sent skipped");
  assert.equal(byName.get("2026-11-24-153012.html")?.title, "Meeting — 2026-11-24 15:30", "title from the md heading, opens the html");
  assert.equal(byName.get("2026-11-24-153012.html")?.snippet, "Agreed the Q3 plan.", "snippet is the first prose line, unbolded");
  assert.equal(byName.get("Acme Kickoff 2026-11-25-090000.html")?.title, "Acme Kickoff", "a named stem shows its name");
  assert.equal(byName.get("Acme Kickoff 2026-11-25-090000.html")?.date, "2026-11-25 09:00", "date from the stamp at the end");
  assert.equal(byName.get("sample.html")?.title, "Sample page", "no md: the html <title>");
  assert.equal(byName.get("2026-11-20-101010.md")?.kind, "notes", "md-only note opens the md");
  assert.equal(byName.get("2026-11-23.html")?.date, "2026-11-23 00:00", "day page dated by its stem");
  const dated = all.filter(e => path.basename(e.file) !== "sample.html").map(e => e.date);
  assert.deepEqual(dated, [...dated].sort().reverse(), "newest first");
  assert.equal(SummaryLibrary.entryDict(byName.get("sample.html")!).ext, "html");
  fs.rmSync(tmp, { recursive: true });
});
