// Runnable check for OrgImport (import body from an ERP snapshot, AI JSON parsing) and CloudSync.importOrg.
//   swiftc -parse-as-library -target arm64-apple-macos15.0 -o /tmp/coi src/CloudSync.swift src/OrgImport.swift check_org_import.swift && /tmp/coi
import Foundation

@main struct Check {
    static func main() {
        let tmp = NSTemporaryDirectory() + "nikxel-oi-" + UUID().uuidString
        try? FileManager.default.createDirectory(atPath: tmp + "/.nikxel", withIntermediateDirectories: true)
        setenv("HOME", tmp, 1); setenv("CFFIXED_USER_HOME", tmp, 1)
        var fails = 0
        func check(_ ok: Bool, _ what: String) { if !ok { fails += 1; print("FAIL: \(what)") } else { print("ok: \(what)") } }
        if NSHomeDirectory() != tmp { print("not sandboxed"); exit(1) }
        func json(_ v: Any) -> String { String(data: try! JSONSerialization.data(withJSONObject: v, options: .sortedKeys), encoding: .utf8)! }

        let snap = OrgSnapshot(people: [
            .init(id: 1, name: "Asha", email: "asha@x.in", title: "CEO", managerID: nil, userID: 11),
            .init(id: 2, name: "Ravi", email: "", title: "Dev", managerID: 1, userID: 12),
            .init(id: 3, name: "Meera", email: "meera@x.in", title: "QA", managerID: 1, userID: 13),
        ], projects: [
            .init(id: 100, name: "Warehouse App", managerUserID: 11, active: true, userIDs: [12, 13, 99], taskNames: ["Fix login", "Ship v2"]),
            .init(id: 200, name: "Old Site", managerUserID: 12, active: true, userIDs: [], taskNames: []),
        ])
        let ai = OrgAI(projects: [100: "Warehouse app for pickers"], people: [2: "Works on Warehouse App"])
        let want: [String: Any] = [
            "people": [
                ["erp_id": 1, "name": "Asha", "email": "asha@x.in", "title": "CEO", "manager_erp_id": NSNull(), "note": ""],
                ["erp_id": 2, "name": "Ravi", "email": "", "title": "Dev", "manager_erp_id": 1, "note": "Works on Warehouse App"],
                ["erp_id": 3, "name": "Meera", "email": "meera@x.in", "title": "QA", "manager_erp_id": 1, "note": ""],
            ],
            "projects": [
                ["erp_id": 100, "name": "Warehouse App", "description": "Warehouse app for pickers", "active": true,
                 "members": [["erp_id": 1, "lead": true], ["erp_id": 2, "lead": false], ["erp_id": 3, "lead": false]]],
                ["erp_id": 200, "name": "Old Site", "description": "", "active": false, "members": [["erp_id": 2, "lead": true]]],
            ],
        ]
        let body = OrgImport.buildImportBody(snap, ai)
        check(json(body) == json(want), "import body shape\n  got  \(json(body))\n  want \(json(want))")
        check(json(OrgImport.buildImportBody(OrgSnapshot(), OrgAI())) == json(["people": [], "projects": []] as [String: Any]), "empty snapshot")
        check(OrgImport.summary(body).hasPrefix("3 people and 2 projects (1 active)") && OrgImport.summary(body).contains("AI wrote from task names"), "summary: \(OrgImport.summary(body))")
        check(OrgImport.prompt(snap).contains("Fix login"), "prompt has task names")

        // Raw Odoo rows -> snapshot: m2o false, membership via hr.employee.user_id, manager -> lead, active = tasks in window.
        let emps: [[String: Any]] = [
            ["id": 1, "name": "Asha", "work_email": "asha@x.in", "job_title": "CEO", "parent_id": false, "user_id": [11, "Asha"] as [Any]],
            ["id": 2, "name": "Ravi", "work_email": false, "job_title": false, "parent_id": [1, "Asha"] as [Any], "user_id": [12, "Ravi"] as [Any]],
            ["id": 3, "name": "Noor", "work_email": false, "job_title": "Ops", "parent_id": [1, "Asha"] as [Any], "user_id": false],
        ]
        let projs: [[String: Any]] = [
            ["id": 100, "name": "Warehouse App", "user_id": [11, "Asha"] as [Any], "active": true],
            ["id": 200, "name": "Old Site", "user_id": false, "active": true],
        ]
        let tasks: [[String: Any]] = [
            ["project_id": [100, "Warehouse App"] as [Any], "user_ids": [12], "name": "Fix login"],
            ["project_id": false, "user_ids": [11], "name": "Loose"],
        ]
        let rowsWant: [String: Any] = [
            "people": [
                ["erp_id": 1, "name": "Asha", "email": "asha@x.in", "title": "CEO", "manager_erp_id": NSNull(), "note": ""],
                ["erp_id": 2, "name": "Ravi", "email": "", "title": "", "manager_erp_id": 1, "note": ""],
                ["erp_id": 3, "name": "Noor", "email": "", "title": "Ops", "manager_erp_id": 1, "note": ""],
            ],
            "projects": [
                ["erp_id": 100, "name": "Warehouse App", "description": "", "active": true, "members": [["erp_id": 1, "lead": true], ["erp_id": 2, "lead": false]]],
                ["erp_id": 200, "name": "Old Site", "description": "", "active": false, "members": [] as [Any]],
            ],
        ]
        let fromRows = OrgImport.snapshot(employees: emps, projects: projs, tasks: tasks)
        check(fromRows.map { json(OrgImport.buildImportBody($0, OrgAI())) } == json(rowsWant), "rows -> snapshot -> body")
        let noEmps = OrgImport.snapshot(employees: nil, projects: projs, tasks: tasks)
        check(noEmps?.people.isEmpty == true && noEmps?.projects.count == 2
              && (noEmps.map { OrgImport.buildImportBody($0, OrgAI()) }?["projects"] as? [[String: Any]])?.first?["active"] as? Bool == true,
              "employees unreadable: projects still go, people empty")
        check(OrgImport.snapshot(employees: emps, projects: nil, tasks: tasks) == nil, "projects unreadable: nothing")
        check(OrgImport.snapshot(employees: emps, projects: projs, tasks: nil) == nil, "tasks unreadable: nothing")

        // Prompt is bounded: active projects only, <= 200, task names <= 80 chars, people only on those projects, <= 60k chars.
        let long = String(repeating: "x", count: 300)
        let big = OrgSnapshot(
            people: (1...2000).map { .init(id: $0, name: $0 == 2000 ? "Lonely" : "P\($0)", email: "", title: "T", managerID: nil, userID: $0) },
            projects: [.init(id: 9999, name: "Dormant", managerUserID: 1, active: true, userIDs: [1], taskNames: [])]
                + (1...300).map { .init(id: $0, name: "Proj\($0)", managerUserID: $0, active: true, userIDs: [$0], taskNames: Array(repeating: long, count: 15)) })
        let bp = OrgImport.prompt(big)
        check(bp.count <= 60_000, "prompt capped: \(bp.count)")
        check(!bp.contains(String(repeating: "x", count: 81)), "task names truncated")
        check(!bp.contains("Dormant") && !bp.contains("Lonely") && !bp.contains("Proj201 "), "only active projects (<=200), people on them")

        let a = OrgImport.parseAI("```json\n{\"projects\":{\"100\":\"Pickers app\"},\"people\":{\"2\":\"Backend\"}}\n```")
        check(a.projects == [100: "Pickers app"] && a.people == [2: "Backend"], "fenced JSON")
        let b = OrgImport.parseAI("Here you go: {\"projects\":{\"7\":\"X\"},\"people\":{}}")
        check(b.projects == [7: "X"] && b.people.isEmpty, "unfenced JSON with chatter")
        let g = OrgImport.parseAI("sorry, no idea")
        check(g.projects.isEmpty && g.people.isEmpty, "garbage -> empty")
        check(OrgImport.parseAI("{\"projects\":[1,2],\"people\":{\"x\":\"y\",\"3\":5}}").people.isEmpty, "wrong types -> empty")

        var seen: (String, String?)?
        let fake: CloudSync.StatusPoster = { path, _, bearer in seen = (path, bearer); return (200, Data("{\"ok\":true}".utf8)) }
        check(CloudSync.importOrg(body, post: fake) == nil && seen == nil, "no token: no post")
        FileManager.default.createFile(atPath: tmp + "/.nikxel/cloud-token", contents: Data("tok123".utf8))
        check(CloudSync.importOrg(body, post: fake) == 200 && seen?.0 == "/api/org/import" && seen?.1 == "tok123", "posts with device token")
        check(CloudSync.importOrg(body, post: { _, _, _ in (403, nil) }) == 403, "403 surfaced")
        check(CloudSync.importOrg(body, post: { _, _, _ in nil }) == nil, "unreachable -> nil")

        print(fails == 0 ? "ALL OK" : "\(fails) FAILED")
        exit(fails == 0 ? 0 : 1)
    }
}
