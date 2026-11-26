// Which project a meeting's minutes are from (projectShare.suggest, port of ProjectShare.suggest).
import { test } from "node:test";
import * as assert from "node:assert/strict";
import { seriesKey, suggest } from "../main/system/projectShare";

test("Push to dashboard suggests the meeting's project", () => {
  const projects = [{ id: "p1", name: "Sarvam Voice Agent" }, { id: "p2", name: "Produce POS" }, { id: "p3", name: "Nikxel" }];
  const none = { titles: {} };
  assert.deepEqual(suggest(projects, "Voice agent dashboard sync", "We wired Sarvam into the call flow.", none)?.id, "p1", "named in the minutes");
  assert.equal(suggest(projects, "Weekly sync", "POS rollout for the produce stores, then produce pricing; Nikxel later.", none)?.id, "p2", "most mentions wins");
  assert.equal(suggest(projects, "Hiring chat", "Nothing about any project.", none), null, "no idea: the user picks");
  assert.equal(suggest(projects, "Hiring chat", "Nothing.", { last: "p3", titles: {} })?.why, "The project you used last.");
  assert.equal(seriesKey("Weekly sync – 12 Nov 2026"), seriesKey("Weekly sync 19 November"), "a series ignores dates");
  const picked = { titles: { [seriesKey("Weekly sync 12 Nov")]: "p3" } };
  assert.equal(suggest(projects, "Weekly sync 19 Nov", "Sarvam Sarvam Sarvam", picked)?.id, "p3", "their own pick for this meeting wins");
  assert.equal(suggest(projects, "Gone", "x", { last: "deleted", titles: {} }), null, "a project they're no longer on isn't suggested");
});
