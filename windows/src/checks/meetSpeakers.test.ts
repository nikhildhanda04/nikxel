// Checks MeetSpeakers' email matching and TranscriptMerger's relabelling of
// "Others" lines with whoever Meet showed talking. Pure, no browser.
import { test } from "node:test";
import * as assert from "node:assert/strict";
import { MeetSpeakers } from "../main/recording/meetSpeakers";
import { TranscriptMerger } from "../main/recording/transcriptMerger";

test("email(for:)", () => {
  const emails = { "Prince Choudhary": "pc@x.com", "ravi@x.com": "ravi@x.com", "anna.k@x.com": "anna.k@x.com", "annabel@x.com": "annabel@x.com" };
  assert.equal(MeetSpeakers.email("prince choudhary", emails), "pc@x.com", "display name, any case");
  assert.equal(MeetSpeakers.email("Ravi Kumar", emails), "ravi@x.com", "first name in the local part");
  assert.equal(MeetSpeakers.email("Anna Lee", emails), null, "two addresses match: no guess");
  assert.equal(MeetSpeakers.email("Al B", { "al@x.com": "al@x.com" }), null, "first name under 3 letters");
});

test("named", () => {
  const spans = [{ start: 0, end: 4, name: "Ravi" }, { start: 4, end: 10, name: "Anna" }];
  assert.equal(TranscriptMerger.named({ start: 2, end: 9 }, spans), "Anna", "most overlap wins");
  assert.equal(TranscriptMerger.named({ start: 3.8, end: 20 }, spans), "Anna", "a quarter is enough");
  assert.equal(TranscriptMerger.named({ start: 9.7, end: 30 }, spans), null, "under a quarter");
  assert.equal(TranscriptMerger.named({ start: 9.7, end: 10.5 }, spans), null, "under half a second");
  assert.equal(TranscriptMerger.named({ start: 20, end: 25 }, spans), null, "nobody talking");
});
