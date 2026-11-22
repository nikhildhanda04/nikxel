// Runnable check for suggestions.ts — port of check_suggestions.swift.
import { test } from "node:test";
import * as assert from "node:assert/strict";
import { replies } from "../main/system/suggestions";

const row = (t: number, name: string, preview: string) => ({ t, name, preview });

test("replies", () => {
  assert.deepEqual(replies([row(100, "Asha", "hi"), row(400, "Asha", "You: ok")], []),
    [{ chat: "Asha", group: false, incomingAt: 100, repliedAt: 400 }], "incoming then own: replied");
  assert.deepEqual(replies([row(100, "Asha", "hi"), row(220, "Asha", "hello?"), row(400, "Asha", "You: ok")], []),
    [{ chat: "Asha", group: false, incomingAt: 100, repliedAt: 400 }], "second incoming doesn't restart the wait");
  assert.deepEqual(replies([row(50, "Asha", "You: hey"), row(500, "Asha", "hi")], []),
    [{ chat: "Asha", group: false, incomingAt: 500, repliedAt: null }], "own first; open wait has no reply");
  const bot = [{ t: 240, name: "Asha", text: "Sure, I'll check" }];
  assert.deepEqual(replies([row(100, "Asha", "hi"), row(250, "Asha", "You: Sure, I'll check"), row(900, "Asha", "You: me now")], bot),
    [{ chat: "Asha", group: false, incomingAt: 100, repliedAt: 900 }], "bot's own reply doesn't close the wait");
  assert.deepEqual(replies([row(100, "Dev", "Ben: lunch?"), row(160, "Dev", "You: yes")], []),
    [{ chat: "Dev", group: true, incomingAt: 100, repliedAt: 160 }], "group chat detected");
  assert.deepEqual(replies([], []), [], "empty input");
});
