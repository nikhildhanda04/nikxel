import Foundation

/// "Share to project" on a meeting page (PageShare /projects and /share-project).
/// Sends the minutes beside the page (<stem>.md, minus its Client Summary) to one
/// of the user's dashboard projects. Mirrors projectShare.ts.
enum ProjectShare {
    /// What a share of the minutes page `file` sends: the stem is the meeting id,
    /// the "# " line the title, the stem's stamp (NoteName) the date.
    /// nil when the page isn't saved meeting minutes.
    static func meeting(_ file: URL) -> (id: String, title: String, date: String, body: String)? {
        guard file.deletingLastPathComponent().lastPathComponent == "meetings",
              let md = try? String(contentsOf: file.deletingPathExtension().appendingPathExtension("md"), encoding: .utf8) else { return nil }
        let stem = file.deletingPathExtension().lastPathComponent
        let title = md.components(separatedBy: "\n").first { $0.hasPrefix("# ") }
            .map { $0.dropFirst(2).trimmingCharacters(in: .whitespaces) } ?? ""
        return (stem, String((title.isEmpty ? "Meeting" : title).prefix(200)), String(NoteName.stamp(stem).prefix(10)), CloudSync.meetingShareBody(md))
    }

    /// `project` nil: {paired, projects, body}, body being exactly what Send would send.
    /// Otherwise sends to that project. Answers through `later`, off the listener queue (both can block 20s).
    static func handle(project: String?, file: URL, later: @escaping ([String: Any]) -> Void) {
        guard let m = meeting(file) else { return later(["error": "Only saved meeting minutes can be shared to a project."]) }
        DispatchQueue.global().async {
            guard let project = project else {
                let paired = CloudSync.token != nil
                return later(["paired": paired, "projects": CloudSync.projects().map { ["id": $0.id, "name": $0.name] }, "body": m.body])
            }
            guard CloudSync.token != nil else { return later(["error": "Connect Nikxel to the dashboard first"]) }
            guard !project.isEmpty else { return later(["error": "Pick a project."]) }
            let ok = CloudSync.shareMeeting(projectID: project, meetingID: m.id, title: m.title, date: m.date, body: m.body)
            cblog("ProjectShare: \(m.id) → \(project): \(ok ? "sent" : "failed")")
            later(ok ? ["ok": true] : ["error": "Couldn't share it. Check you're still on that project, then try again."])
        }
    }
}
