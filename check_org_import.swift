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
        check(OrgImport.summary(body).hasPrefix("3 people and 2 projects (1 active)"), "summary: \(OrgImport.summary(body))")
        check(OrgImport.prompt(snap).contains("Fix login"), "prompt has task names")

        let a = OrgImport.parseAI("```json\n{\"projects\":{\"100\":\"Pickers app\"},\"people\":{\"2\":\"Backend\"}}\n```")
        check(a.projects == [100: "Pickers app"] && a.people == [2: "Backend"], "fenced JSON")
        let b = OrgImport.parseAI("Here you go: {\"projects\":{\"7\":\"X\"},\"people\":{}}")
        check(b.projects == [7: "X"] && b.people.isEmpty, "unfenced JSON with chatter")
        let g = OrgImport.parseAI("sorry, no idea")
        check(g.projects.isEmpty && g.people.isEmpty, "garbage -> empty")
        check(OrgImport.parseAI("{\"projects\":[1,2],\"people\":{\"x\":\"y\",\"3\":5}}").people.isEmpty, "wrong types -> empty")

        var seen: (String, String?)?
        let fake: CloudSync.Poster = { path, _, bearer in seen = (path, bearer); return Data("{\"ok\":true}".utf8) }
        check(!CloudSync.importOrg(body, post: fake) && seen == nil, "no token: no post")
        FileManager.default.createFile(atPath: tmp + "/.nikxel/cloud-token", contents: Data("tok123".utf8))
        check(CloudSync.importOrg(body, post: fake) && seen?.0 == "/api/org/import" && seen?.1 == "tok123", "posts with device token")
        check(!CloudSync.importOrg(body, post: { _, _, _ in nil }), "failed post -> false")

        print(fails == 0 ? "ALL OK" : "\(fails) FAILED")
        exit(fails == 0 ? 0 : 1)
    }
}
