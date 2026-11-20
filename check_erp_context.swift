// Runnable check for ErpContext — the sealed ERP-facts store, its injected
// block, the reader prompt, and the accept/bound guards.
//   swiftc -parse-as-library -target arm64-apple-macos15.0 -o /tmp/cec \
//     src/ErpContext.swift check_erp_context.swift && /tmp/cec
import Foundation

func cblog(_ msg: String) { print("log: \(msg)") } // stand-in for the app's logger

@main struct Check {
    static func main() {
        // Never touch the real profile: point HOME at a fresh temp dir first.
        let tmp = NSTemporaryDirectory() + "nikxel-erp-" + UUID().uuidString
        try? FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
        setenv("HOME", tmp, 1)
        setenv("CFFIXED_USER_HOME", tmp, 1) // NSHomeDirectory() on macOS honors this, not HOME
        var fails = 0
        func check(_ ok: Bool, _ what: String) { if !ok { fails += 1; print("FAIL: \(what)") } else { print("ok: \(what)") } }

        print("NSHomeDirectory() = \(NSHomeDirectory())")
        check(NSHomeDirectory() == tmp, "check is sandboxed to temp HOME")
        if NSHomeDirectory() != tmp { exit(1) }

        // accept: keeps old on blank / refusal; takes and caps new.
        check(ErpContext.accept(new: "", old: "OLD") == "OLD", "accept keeps old on empty")
        check(ErpContext.accept(new: "   \n ", old: "OLD") == "OLD", "accept keeps old on whitespace")
        check(ErpContext.accept(new: "Project Rentop — yours — due Fri", old: "") == "Project Rentop — yours — due Fri", "accept takes real facts")
        check(ErpContext.accept(new: String(repeating: "x", count: 2500), old: "").count <= 2000, "accept caps length")
        check(ErpContext.accept(new: "Who\nl1\nl2\nl3", old: "", cap: 8) == "Who\nl1", "accept cuts on a line boundary")
        check(ErpContext.accept(new: "مشروع رينتوب — مستحق الجمعة", old: "OLD") == "مشروع رينتوب — مستحق الجمعة", "accept keeps non-Latin facts")

        // skipLink: deny logout/delete-style GET links, allow ordinary views.
        check(ErpContext.skipLink("https://erp.x.com/web/session/logout") == true, "skipLink denies logout")
        check(ErpContext.skipLink("https://erp.x.com/app?action=delete&id=7") == true, "skipLink denies delete")
        check(ErpContext.skipLink("https://erp.x.com/odoo/contacts") == false, "skipLink allows views")

        // boundText: caps total, joins sections.
        check(ErpContext.boundText(sections: [String(repeating: "a", count: 5000), String(repeating: "b", count: 5000)], cap: 8000).count <= 8000, "boundText caps total")
        let bt = ErpContext.boundText(sections: ["one", "two"])
        check(bt.contains("one") && bt.contains("two"), "boundText joins sections")

        // readerPrompt carries the captured text.
        check(ErpContext.readerPrompt(capturedText: "CAPTURED ERP TEXT HERE").contains("CAPTURED ERP TEXT HERE"), "readerPrompt carries the captured text")

        // injectedBlock: empty store ⇒ empty block; non-empty ⇒ header + facts.
        ErpContext.facts = ""
        check(ErpContext.injectedBlock == "", "empty store injects nothing")
        ErpContext.facts = "Customer C&N Distributors — active"
        let ib = ErpContext.injectedBlock
        check(ib.contains("Customer C&N Distributors"), "block has the facts")
        check(ib.count > "Customer C&N Distributors — active".count, "block has a header line")

        // file is 0600 and empty removes it.
        let f = NSHomeDirectory() + "/.nikxel/twin/erp.md"
        let perm = (try? FileManager.default.attributesOfItem(atPath: f)[.posixPermissions] as? Int) ?? 0
        check(perm == 0o600, "erp.md is 0600")
        ErpContext.facts = ""
        check(!FileManager.default.fileExists(atPath: f), "empty removes file")

        // ingestWith: keeps old facts on empty capture; stores new facts otherwise.
        ErpContext.facts = "OLD FACTS"
        ErpContext.ingestWith(capture: { [] }, runPrompt: { _, _ in "NEW" })
        check(ErpContext.facts == "OLD FACTS", "ingest keeps old facts on empty capture")
        ErpContext.ingestWith(capture: { ["Project Rentop — yours"] }, runPrompt: { _, _ in "Project Rentop — yours — due Fri" })
        check(ErpContext.facts.contains("Rentop"), "ingest stores new facts")
        ErpContext.facts = ""

        if fails > 0 { exit(1) }
    }
}
