// Port of check_org_import.swift: import body from an ERP snapshot, AI JSON parsing, CloudSync.importOrg.
import { test } from "node:test";
import * as assert from "node:assert/strict";
import * as fs from "fs";
import * as os from "os";
import * as path from "path";
import { buildImportBody, parseAI, summary, prompt, OrgSnapshot } from "../main/system/orgImport";

const snap: OrgSnapshot = {
  people: [
    { id: 1, name: "Asha", email: "asha@x.in", title: "CEO", managerID: null, userID: 11 },
    { id: 2, name: "Ravi", email: "", title: "Dev", managerID: 1, userID: 12 },
    { id: 3, name: "Meera", email: "meera@x.in", title: "QA", managerID: 1, userID: 13 },
  ],
  projects: [
    { id: 100, name: "Warehouse App", managerUserID: 11, active: true, userIDs: [12, 13, 99], taskNames: ["Fix login", "Ship v2"] },
    { id: 200, name: "Old Site", managerUserID: 12, active: true, userIDs: [], taskNames: [] },
  ],
};

test("buildImportBody: members from task assignees, manager is lead, no tasks = inactive", () => {
  const body = buildImportBody(snap, { projects: { 100: "Warehouse app for pickers" }, people: { 2: "Works on Warehouse App" } });
  assert.deepEqual(body, {
    people: [
      { erp_id: 1, name: "Asha", email: "asha@x.in", title: "CEO", manager_erp_id: null, note: "" },
      { erp_id: 2, name: "Ravi", email: "", title: "Dev", manager_erp_id: 1, note: "Works on Warehouse App" },
      { erp_id: 3, name: "Meera", email: "meera@x.in", title: "QA", manager_erp_id: 1, note: "" },
    ],
    projects: [
      { erp_id: 100, name: "Warehouse App", description: "Warehouse app for pickers", active: true,
        members: [{ erp_id: 1, lead: true }, { erp_id: 2, lead: false }, { erp_id: 3, lead: false }] },
      { erp_id: 200, name: "Old Site", description: "", active: false, members: [{ erp_id: 2, lead: true }] },
    ],
  });
  assert.ok(summary(body).startsWith("3 people and 2 projects (1 active)"), summary(body));
  assert.ok(prompt(snap).includes("Fix login"));
});

test("buildImportBody: empty snapshot", () => {
  assert.deepEqual(buildImportBody({ people: [], projects: [] }, { projects: {}, people: {} }), { people: [], projects: [] });
});

test("parseAI: fenced, unfenced, garbage", () => {
  assert.deepEqual(parseAI("```json\n{\"projects\":{\"100\":\"Pickers app\"},\"people\":{\"2\":\"Backend\"}}\n```"), { projects: { 100: "Pickers app" }, people: { 2: "Backend" } });
  assert.deepEqual(parseAI("Here you go: {\"projects\":{\"7\":\"X\"},\"people\":{}}"), { projects: { 7: "X" }, people: {} });
  assert.deepEqual(parseAI("sorry, no idea"), { projects: {}, people: {} });
  assert.deepEqual(parseAI("{\"projects\":[1,2],\"people\":{\"x\":\"y\",\"3\":5}}"), { projects: {}, people: {} });
});

test("CloudSync.importOrg: no token no post; posts with device token", async () => {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), "nikxel-oi-"));
  process.env.HOME = home; process.env.USERPROFILE = home; // before paths.ts reads os.homedir()
  // eslint-disable-next-line @typescript-eslint/no-var-requires
  const CS = require("../main/system/cloudSync").CloudSync;
  let seen: [string, string | null] | null = null;
  const fake = async (p: string, _b: unknown, bearer: string | null) => { seen = [p, bearer]; return { ok: true }; };
  assert.equal(await CS.importOrg({ people: [], projects: [] }, fake), false);
  assert.equal(seen, null);
  fs.mkdirSync(path.dirname(CS.tokenFile()), { recursive: true });
  fs.writeFileSync(CS.tokenFile(), "tok123");
  assert.equal(await CS.importOrg({ people: [], projects: [] }, fake), true);
  assert.deepEqual(seen, ["/api/org/import", "tok123"]);
  assert.equal(await CS.importOrg({}, async () => null), false);
});
