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
            + "project members and leads, and short AI-written notes. Task names stay on this Mac."
    }

    static func prompt(_ s: OrgSnapshot) -> String {
        var out = """
        You are mapping a company's ERP into an org chart. For each project, write a one-line description \
        (at most 15 words) of what it is, from its name and recent task names. For each person, write a short \
        "works on" note (at most 15 words) from their title and projects. Use only what is given; never invent \
        clients, numbers or dates. Reply with ONLY this JSON, keys being the ids in brackets:
        {"projects":{"<id>":"<description>"},"people":{"<id>":"<note>"}}

        PROJECTS

        """
        var onProjects: [Int: [String]] = [:]
        for p in s.projects {
            out += "- [\(p.id)] \(p.name)" + (p.taskNames.isEmpty ? "" : " — recent tasks: " + p.taskNames.joined(separator: "; ")) + "\n"
            for m in members(p, s.people) { onProjects[m.person.id, default: []].append(p.name) }
        }
        out += "\nPEOPLE\n"
        for e in s.people {
            out += "- [\(e.id)] \(e.name)" + (e.title.isEmpty ? "" : " — \(e.title)")
                + (onProjects[e.id].map { " — on: " + $0.joined(separator: ", ") } ?? "") + "\n"
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
