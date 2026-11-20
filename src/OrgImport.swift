import Foundation

/// What ERP.orgSnapshot() reads. Task names are for the AI prompt only and never leave the Mac.
struct OrgSnapshot {
    struct Person { let id: Int; let name, email, title: String; let managerID: Int?; let userID: Int? }
    /// `userIDs`: res.users ids assigned to the project's tasks in the window; `active`: Odoo's flag.
    struct Project { let id: Int; let name: String; let managerUserID: Int?; let active: Bool; let userIDs: [Int]; let taskNames: [String] }
    var people: [Person] = []
    var projects: [Project] = []
}

/// The AI's notes, keyed by erp_id.
struct OrgAI { var projects: [Int: String] = [:]; var people: [Int: String] = [:] }

/// "Build org from ERP…": snapshot -> one AI prompt -> import body -> (dialog) -> POST /api/org/import.
/// DATA BOUNDARY: only the body below is sent: people {erp_id,name,email,title,manager_erp_id,note},
/// projects {erp_id,name,description,active,members:[{erp_id,lead}]}. Mirrors orgImport.ts.
enum OrgImport {
    /// Members are employees whose user is on the project's tasks; the project manager is the lead.
    private static func members(_ p: OrgSnapshot.Project, _ people: [OrgSnapshot.Person]) -> [(person: OrgSnapshot.Person, lead: Bool)] {
        let on = Set(p.userIDs)
        return people.compactMap { e in
            guard let u = e.userID else { return nil }
            let lead = u == p.managerUserID
            return lead || on.contains(u) ? (e, lead) : nil
        }
    }

    static func buildImportBody(_ s: OrgSnapshot, _ ai: OrgAI) -> [String: Any] {
        let people = s.people.filter { !$0.name.isEmpty }.prefix(2000)
        return [
            "people": people.map { p -> [String: Any] in
                ["erp_id": p.id, "name": p.name, "email": p.email, "title": p.title,
                 "manager_erp_id": p.managerID.map { $0 as Any } ?? NSNull(), "note": ai.people[p.id] ?? ""]
            },
            "projects": s.projects.filter { !$0.name.isEmpty }.prefix(1000).map { p -> [String: Any] in
                ["erp_id": p.id, "name": p.name, "description": ai.projects[p.id] ?? "", "active": p.active && !p.taskNames.isEmpty,
                 "members": members(p, Array(people)).map { ["erp_id": $0.person.id, "lead": $0.lead] as [String: Any] }]
            },
        ]
    }

    /// The confirmation dialog's text: counts and exactly which fields go.
    static func summary(_ body: [String: Any]) -> String {
        let people = (body["people"] as? [Any])?.count ?? 0
        let projects = body["projects"] as? [[String: Any]] ?? []
        let active = projects.filter { $0["active"] as? Bool == true }.count
        return "\(people) people and \(projects.count) projects (\(active) active) — names, work emails, job titles, managers, "
            + "project members and leads, plus project descriptions and people notes that AI wrote from task names "
            + "(the task names themselves are not sent to the dashboard)."
    }

    /// Odoo search_read rows -> snapshot. Employees unreadable -> no people (projects still go);
    /// projects or tasks unreadable -> nil (nothing to send). Keeps up to 15 task names per project.
    static func snapshot(employees: [[String: Any]]?, projects: [[String: Any]]?, tasks: [[String: Any]]?) -> OrgSnapshot? {
        guard let projects, let tasks else { return nil }
        // Many2one fields come back as [id, "Name"] or false.
        func m2o(_ v: Any?) -> Int? { (v as? [Any])?.first as? Int }
        func str(_ v: Any?) -> String { v as? String ?? "" }
        var users: [Int: Set<Int>] = [:], names: [Int: [String]] = [:]
        for t in tasks {
            guard let p = m2o(t["project_id"]) else { continue }
            users[p, default: []].formUnion(t["user_ids"] as? [Int] ?? [])
            if names[p, default: []].count < 15 { names[p, default: []].append(str(t["name"])) }
        }
        return OrgSnapshot(
            people: (employees ?? []).compactMap { r in
                guard let id = r["id"] as? Int else { return nil }
                return .init(id: id, name: str(r["name"]), email: str(r["work_email"]), title: str(r["job_title"]),
                             managerID: m2o(r["parent_id"]), userID: m2o(r["user_id"]))
            },
            projects: projects.compactMap { r in
                guard let id = r["id"] as? Int else { return nil }
                return .init(id: id, name: str(r["name"]), managerUserID: m2o(r["user_id"]), active: r["active"] as? Bool ?? true,
                             userIDs: Array(users[id] ?? []).sorted(), taskNames: names[id] ?? [])
            })
    }

    /// Bounded: active projects only (at most 200), task names cut to 80 chars, people only when on
    /// one of those projects, and the whole prompt at most 60k chars (lines past that are dropped).
    static func prompt(_ s: OrgSnapshot) -> String {
        var out = """
        You are mapping a company's ERP into an org chart. For each project, write a one-line description \
        (at most 15 words) of what it is, from its name and recent task names. For each person, write a short \
        "works on" note (at most 15 words) from their title and projects. Use only what is given; never invent \
        clients, numbers or dates. Reply with ONLY this JSON, keys being the ids in brackets:
        {"projects":{"<id>":"<description>"},"people":{"<id>":"<note>"}}

        PROJECTS

        """
        var size = out.count
        func add(_ line: String) { if size + line.count <= 60_000 { out += line; size += line.count } }
        var onProjects: [Int: [String]] = [:]
        for p in s.projects.filter({ $0.active && !$0.taskNames.isEmpty }).prefix(200) {
            add("- [\(p.id)] \(p.name) — recent tasks: " + p.taskNames.map { String($0.prefix(80)) }.joined(separator: "; ") + "\n")
            for m in members(p, s.people) { onProjects[m.person.id, default: []].append(p.name) }
        }
        add("\nPEOPLE\n")
        for e in s.people {
            guard let on = onProjects[e.id] else { continue }
            add("- [\(e.id)] \(e.name)" + (e.title.isEmpty ? "" : " — \(e.title)") + " — on: " + on.joined(separator: ", ") + "\n")
        }
        return out
    }

    /// The AI reply's JSON object (fenced or not, chatter around it ignored); empty maps when it doesn't parse.
    static func parseAI(_ text: String) -> OrgAI {
        guard let a = text.firstIndex(of: "{"), let b = text.lastIndex(of: "}"), a < b,
              let obj = try? JSONSerialization.jsonObject(with: Data(text[a...b].utf8)) as? [String: Any] else { return OrgAI() }
        func map(_ v: Any?) -> [Int: String] {
            var out: [Int: String] = [:]
            for (k, v) in v as? [String: Any] ?? [:] { if let id = Int(k), let s = v as? String { out[id] = s } }
            return out
        }
        return OrgAI(projects: map(obj["projects"]), people: map(obj["people"]))
    }
}
