// Checks pulling the reply out of Antigravity CLI's stream-json output.
import { test } from "node:test";
import * as assert from "node:assert/strict";
import { parseAgyStreamJSON } from "../main/recording/momGenerator";

test("agy stream-json reply", () => {
  const out = [
    '{"event":"init","conversation_id":"c1"}',
    '{"event":"step_update","text":"thinking"}',
    '{"event":"result","status":"SUCCESS","response":"# Meeting\\nDone."}',
    "",
  ].join("\n");
  assert.equal(parseAgyStreamJSON(out), "# Meeting\nDone.");
  assert.equal(parseAgyStreamJSON('{"type":"result","result":"ok"}'), "ok");
  assert.equal(parseAgyStreamJSON('{"event":"init"}\nnot json'), null, "no result event");
});
