// swiftc src/WhatsNew.swift checks/check_whats_new.swift -o /tmp/cwn && /tmp/cwn
import Foundation

@main struct CheckWhatsNew {
    static func main() throws {
        var fails = 0
        func check(_ ok: Bool, _ what: String) { if !ok { fails += 1; print("FAIL: \(what)") } else { print("ok: \(what)") } }
        let md = """
        # What's new
        Intro text, ignored.
        <!--
        ## not a release
        -->
        ## 2026-11-26
        ### Org
        Your team's side.
        Second line.

        New paragraph.
        tour: org-home | Your organization | The overview.
        tour: org-chart
        ### A fix
        Renaming finishes.
        ## 2026-11-25
        ### Window
        tour: home
        Everything here.
        """
        let r = WhatsNew.parse(md)
        check(r.map(\.id) == ["2026-11-26", "2026-11-25"], "releases in order, comments skipped")
        check(r[0].items.map(\.title) == ["Org", "A fix"], "items")
        check(r[0].items[0].body == "Your team's side. Second line.\n\nNew paragraph.", "paragraphs, tour lines left out")
        check(r[0].items[0].tour == [WhatsNew.Step(section: "org-home", title: "Your organization", text: "The overview."),
                                    WhatsNew.Step(section: "org-chart", title: "Org", text: r[0].items[0].body)], "steps, with defaults")
        check(r[0].items[1].tour.isEmpty, "a fix has no tour")
        check(r[1].items[0].tour.first?.section == "home" && r[1].items[0].body == "Everything here.", "tour line before the paragraph")
        check(WhatsNew.unseen(r, seen: nil) == ["2026-11-26"], "never seen: only the newest")
        check(WhatsNew.unseen(r, seen: "2026-11-25") == ["2026-11-26"], "above the seen one")
        check(WhatsNew.unseen(r, seen: "2026-11-26").isEmpty, "all seen")
        check(WhatsNew.unseen(r, seen: "2026-01-01") == ["2026-11-26", "2026-11-25"], "seen one gone: everything")
        let day = [WhatsNew.Release(id: "2026-11-27.2", items: []), WhatsNew.Release(id: "2026-11-27", items: []), WhatsNew.Release(id: "2026-11-26", items: [])]
        check(WhatsNew.unseen(day, seen: nil) == ["2026-11-27.2", "2026-11-27"], "never seen: all of the newest day")
        let real = WhatsNew.parse(try String(contentsOfFile: "WHATSNEW.md", encoding: .utf8))
        check(!real.isEmpty && real.allSatisfy { !$0.items.isEmpty }, "WHATSNEW.md parses, every update has changes")
        let sections: Set = ["home", "chat", "library", "tasks", "automations", "people", "activity", "whatsnew", "you", "meetings", "whatsapp",
                             "connections", "advanced", "org-home", "org-chart", "org-projects", "org-roles", "org-shared", "org-connection", "meeting"]
        let bad = real.flatMap(\.items).flatMap(\.tour).filter { !sections.contains($0.section) }.map(\.section)
        check(bad.isEmpty, "every tour step names a real section \(bad)")
        print(fails == 0 ? "all good" : "\(fails) failed")
        if fails > 0 { exit(1) }
    }
}
