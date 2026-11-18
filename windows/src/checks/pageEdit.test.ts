// Checks the Edit chat's reply parser: NOTE/RENAME before "---", the summary
// after it, and anything without a "# " title turned away.
import { test } from "node:test";
import * as assert from "node:assert/strict";
import { parseReply } from "../main/system/pageEdit";

test("edit reply splits into note, renames and Markdown", () => {
  const r = parseReply("NOTE: Renamed Speaker 3.\nRENAME: Speaker 3 => Rahul\nRENAME: bad line\n---\n# Meeting\n\n- Rahul owns it\n");
  assert.deepEqual(r, { note: "Renamed Speaker 3.", renames: [["Speaker 3", "Rahul"]], markdown: "# Meeting\n\n- Rahul owns it\n" });
  assert.equal(parseReply("\n---\n# T")?.note, "Updated.");
});

test("edit reply without a summary is rejected", () => {
  assert.equal(parseReply("NOTE: Couldn't do it."), null);
  assert.equal(parseReply("---\n# T\n"), null);  // the separator needs a line before it, as on the Mac
  assert.equal(parseReply("NOTE: hi\n---\nSure, here's the summary"), null);
});
