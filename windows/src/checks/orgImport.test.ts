// Port of check_org_import.swift: import body from an ERP snapshot, AI JSON parsing, CloudSync.importOrg.
import { test } from "node:test";
import * as assert from "node:assert/strict";
import * as fs from "fs";
import * as os from "os";
import * as path from "path";
import { buildImportBody, parseAI, summary, prompt, snapshot, OrgSnapshot } from "../main/system/orgImport";

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
  assert.ok(summary(body).startsWith("3 people and 2 projects (1 active)") && summary(body).includes("AI wrote from task names"), summary(body));
  assert.ok(prompt(snap).includes("Fix login"));
});

test("buildImportBody: empty snapshot", () => {
  assert.deepEqual(buildImportBody({ people: [], projects: [] }, { projects: {}, people: {} }), { people: [], projects: [] });
});

test("snapshot: raw Odoo rows, m2o false, membership via employee user_id, manager lead", () => {
  const emps = [
    { id: 1, name: "Asha", work_email: "asha@x.in", job_title: "CEO", parent_id: false, user_id: [11, "Asha"] },
    { id: 2, name: "Ravi", work_email: false, job_title: false, parent_id: [1, "Asha"], user_id: [12, "Ravi"] },
    { id: 3, name: "Noor", work_email: false, job_title: "Ops", parent_id: [1, "Asha"], user_id: false },
  ];
  const projs = [{ id: 100, name: "Warehouse App", user_id: [11, "Asha"], active: true }, { id: 200, name: "Old Site", user_id: false, active: true }];
  const tasks = [{ project_id: [100, "Warehouse App"], user_ids: [12], name: "Fix login" }, { project_id: false, user_ids: [11], name: "Loose" }];
  const s = snapshot(emps, projs, tasks);
  assert.ok(s);
  assert.deepEqual(buildImportBody(s, { projects: {}, people: {} }), {
    people: [
      { erp_id: 1, name: "Asha", email: "asha@x.in", title: "CEO", manager_erp_id: null, note: "" },
      { erp_id: 2, name: "Ravi", email: "", title: "", manager_erp_id: 1, note: "" },
      { erp_id: 3, name: "Noor", email: "", title: "Ops", manager_erp_id: 1, note: "" },
    ],
    projects: [
      { erp_id: 100, name: "Warehouse App", description: "", active: true, members: [{ erp_id: 1, lead: true }, { erp_id: 2, lead: false }] },
      { erp_id: 200, name: "Old Site", description: "", active: false, members: [] },
    ],
  });
  const noEmps = snapshot(null, projs, tasks);
  assert.ok(noEmps && noEmps.people.length === 0 && noEmps.projects.length === 2);
  assert.equal(buildImportBody(noEmps, { projects: {}, people: {} }).projects[0].active, true);
  assert.equal(snapshot(emps, null, tasks), null);
  assert.equal(snapshot(emps, projs, null), null);
});

test("prompt is bounded: active projects only, <= 200, task names <= 80, people on them, <= 60k", () => {
  const long = "x".repeat(300);
  const big: OrgSnapshot = {
    people: Array.from({ length: 2000 }, (_, i) => ({ id: i + 1, name: i + 1 === 2000 ? "Lonely" : `P${i + 1}`, email: "", title: "T", managerID: null, userID: i + 1 })),
    projects: [{ id: 9999, name: "Dormant", managerUserID: 1, active: true, userIDs: [1], taskNames: [] },
      ...Array.from({ length: 300 }, (_, i) => ({ id: i + 1, name: `Proj${i + 1}`, managerUserID: i + 1, active: true, userIDs: [i + 1], taskNames: Array(15).fill(long) }))],
  };
  const p = prompt(big);
  assert.ok(p.length <= 60000, String(p.length));
  assert.ok(!p.includes("x".repeat(81)));
  assert.ok(!p.includes("Dormant") && !p.includes("Lonely") && !p.includes("Proj201 "));
});

test("parseAI: fenced, unfenced, garbage", () => {
  assert.deepEqual(parseAI("```json\n{\"projects\":{\"100\":\"Pickers app\"},\"people\":{\"2\":\"Backend\"}}\n```"), { projects: { 100: "Pickers app" }, people: { 2: "Backend" } });
  assert.deepEqual(parseAI("Here you go: {\"projects\":{\"7\":\"X\"},\"people\":{}}"), { projects: { 7: "X" }, people: {} });
  assert.deepEqual(parseAI("sorry, no idea"), { projects: {}, people: {} });
  assert.deepEqual(parseAI("{\"projects\":[1,2],\"people\":{\"x\":\"y\",\"3\":5}}"), { projects: {}, people: {} });
});

test("CloudSync.importOrg: no token no post; status surfaced", async () => {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), "nikxel-oi-"));
  process.env.HOME = home; process.env.USERPROFILE = home; // before paths.ts reads os.homedir()
  // eslint-disable-next-line @typescript-eslint/no-var-requires
  const CS = require("../main/system/cloudSync").CloudSync;
  let seen: [string, string | null] | null = null;
  const fake = async (p: string, _b: unknown, bearer: string | null) => { seen = [p, bearer]; return 200; };
  assert.equal(await CS.importOrg({ people: [], projects: [] }, fake), null);
  assert.equal(seen, null);
  fs.mkdirSync(path.dirname(CS.tokenFile()), { recursive: true });
  fs.writeFileSync(CS.tokenFile(), "tok123");
  assert.equal(await CS.importOrg({ people: [], projects: [] }, fake), 200);
  assert.deepEqual(seen, ["/api/org/import", "tok123"]);
  assert.equal(await CS.importOrg({}, async () => 403), 403);
  assert.equal(await CS.importOrg({}, async () => null), null);
});
