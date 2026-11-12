// Checks the self-updater's decisions: when a tap to update is offered at all,
// and how a commit subject is shortened for the card. Port of check_updater.swift.
import { test } from "node:test";
import * as assert from "node:assert/strict";
import { Updater, makeStatus } from "../main/system/updater";

const status = (behind: number, branch = "main", dirty = false) =>
  makeStatus({ repo: "C:\\repo", behind, subjects: [], currentCommit: "abc1234", branch, dirty });

test("when the tap is offered", () => {
  assert.ok(status(0).isUpToDate);
  assert.ok(!status(1).isUpToDate);

  // A fast-forward pull needs main AND a clean tree. Offering a tap that
  // cannot work means the update script discovers it, fails, and rolls
  // back -- a wasted quit and rebuild for something knowable up front.
  assert.ok(status(2).canAutoUpdate);
  assert.ok(!status(2, "experiment").canAutoUpdate, "a branch other than main can't fast-forward to origin/main");
  assert.ok(!status(2, "main", true).canAutoUpdate, "uncommitted changes block the pull");
  assert.ok(!status(2, "experiment", true).canAutoUpdate);
  // Being up to date says nothing about whether a pull *could* run.
  assert.ok(status(0).canAutoUpdate);
});

test("shortening a subject for a card line", () => {
  const short = "Fix the thing";
  assert.equal(Updater.shortSubject(short), short, "a short subject is untouched");

  const long = "Don't abort the build on a Mac that lacks the signing certificate";
  const cut = (Updater.shortSubject as (s: string, limit?: number) => string)(long, 56);
  assert.ok(Array.from(cut).length <= 57, `within the limit plus the ellipsis — got ${cut.length}`);
  assert.ok(cut.endsWith("…"));
  assert.ok(!cut.endsWith(" …"), "no space left dangling before the ellipsis");
  // The whole point: never slice a word in half.
  const body = cut.slice(0, -1);
  assert.ok(long.startsWith(body), "the kept text is a real prefix of the subject");
  assert.equal(long[body.length], " ", `the cut landed on a word boundary — got '${body}'`);

  const sub = Updater.shortSubject as (s: string, limit?: number) => string;
  // Exactly at the limit is not truncated.
  const exact = "a".repeat(20);
  assert.equal(sub(exact, 20), exact);
  assert.ok(sub(exact, 19).endsWith("…"));
  // One long token with no space to back up to still has to be cut.
  assert.equal(sub("x".repeat(100), 10), "x".repeat(10) + "…");
  // Leading/trailing whitespace is trimmed, not counted.
  assert.equal(Updater.shortSubject("   padded   "), "padded");
});
