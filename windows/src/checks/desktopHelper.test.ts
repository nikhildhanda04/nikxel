// The one PowerShell behind the agent monitor, the foreground sampler and the
// meeting detector is assembled from three scripts; a slip in the joins would
// break all three at once, on Windows only. Checks the shape.
import { test } from "node:test";
import * as assert from "node:assert/strict";
import { script } from "../main/system/desktopHelper";
import { PS_END } from "../main/system/psHelper";

test("the merged helper script is well formed", () => {
  const s = script();
  assert.match(s, /^Add-Type -TypeDefinition @'\n/, "here-string opens on its own line");
  assert.match(s, /\n'@\n/, "and closes at the start of a line");
  assert.equal((s.match(/public static class Nx(MeetWin|Fg)/g) ?? []).length, 2, "both shims, compiled once");
  for (const k of ["agent", "fg", "meet"]) assert.match(s, new RegExp(`\\n\\s+'${k}' \\{`), `answers "${k}"`);
  assert.equal((s.match(new RegExp(PS_END, "g")) ?? []).length, 1, "one end marker, after every answer");
  assert.doesNotMatch(s, /\$\{/, "no template left unfilled");
  assert.match(s, /'\*claude\*'/, "agent names are in");
  assert.match(s, /\$fgNames/);
  assert.doesNotMatch(s, /\$names\b/, "the two old \$names variables were renamed apart");
});
