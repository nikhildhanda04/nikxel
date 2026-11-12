// Runnable checks for Settings' firstName: the fallback that stopped every
// user's notes from calling them "Nikhil". Port of the firstName half of
// check_user_name.swift (its stampedVersion half belongs to MOMGenerator).
import { test } from "node:test";
import * as assert from "node:assert/strict";
import { firstName } from "../main/core/settings";

test("firstName", () => {
  const eq = (full: string, account: string, want: string | null, why: string) =>
    assert.equal(firstName(full, account), want, `${why}: firstName("${full}", "${account}")`);
  eq("Prince Choudhary", "prince", "Prince", "full name");
  eq("prince choudhary", "prince", "Prince", "lowercase full name is capitalized");
  eq("Priya", "psharma", "Priya", "single first name that isn't the login");
  eq("princechoudhary", "princechoudhary", null, "bare login is not a name");
  eq("admin2", "admin2", null, "digits mean it's an account, not a name");
  eq("jake@viziontools.com", "jake", null, "email is not a name");
  eq("", "jake", null, "empty full name");
  eq("  ", "jake", null, "whitespace-only full name");
  eq("J Smith", "j", null, "single-letter first name is an initial");
});
