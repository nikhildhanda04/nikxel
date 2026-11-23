// Runnable check for chat-initiated ERP tasks (ERP.looksLikeTaskRequest, parseTaskDraft,
// taskDraftPrompt). ERP pulls in the app, so compile against all of src/ with @main removed:
//   sed 's/^@main$//' src/NikxelApp.swift > /tmp/NikxelApp_et.swift && swiftc -parse-as-library \
//     -target arm64-apple-macos15.0 -o /tmp/cet $(ls src/*.swift | grep -v NikxelApp.swift) \
//     /tmp/NikxelApp_et.swift check_erp_task.swift && /tmp/cet
import Foundation

@main struct CheckErpTask {
    static func main() {
        var fails = 0
        func check(_ ok: Bool, _ what: String) { if !ok { fails += 1; print("FAIL: \(what)") } else { print("ok: \(what)") } }

        // looksLikeTaskRequest: creation verb before "task" fires; questions about existing tasks don't
        check(ERP.looksLikeTaskRequest("make a task to send Piyush the invoice"), "make a task")
        check(ERP.looksLikeTaskRequest("create an ERP task for the login bug"), "create an ERP task")
        check(ERP.looksLikeTaskRequest("add a new task: follow up with Prince"), "add a new task")
        check(ERP.looksLikeTaskRequest("log a task for the deployment"), "log a task")
        check(ERP.looksLikeTaskRequest("set up a task to review the PR"), "set up a task")
        check(!ERP.looksLikeTaskRequest("what tasks did I create today?"), "question about existing tasks -> no")
        check(!ERP.looksLikeTaskRequest("how many tasks are open"), "count question -> no")
        check(!ERP.looksLikeTaskRequest("summarize my last meeting"), "unrelated -> no")
        check(!ERP.looksLikeTaskRequest("make the summary shorter"), "verb without task -> no")

        // parseTaskDraft: strict JSON, code fences, prose around it, nulls, missing title
        let clean = #"{"title":"Send invoice to Piyush","body":"Email the Oct invoice.","assignee":"Piyush","project":"Finance","due":"2026-11-27"}"#
        let d = ERP.parseTaskDraft(clean)
        check(d?.title == "Send invoice to Piyush", "title parsed: \(d?.title ?? "nil")")
        check(d?.assignee == "Piyush" && d?.project == "Finance" && d?.due == "2026-11-27", "fields parsed")

        let fenced = "Sure!\n```json\n" + #"{"title":"Fix login","body":"The SSO redirect loops.","assignee":null,"project":null,"due":null}"# + "\n```\n"
        let d2 = ERP.parseTaskDraft(fenced)
        check(d2?.title == "Fix login", "fenced+prose title: \(d2?.title ?? "nil")")
        check(d2?.assignee == nil && d2?.project == nil && d2?.due == nil, "json null -> nil")
        check(d2?.body == "The SSO redirect loops.", "body parsed")

        // "null" as a string value also becomes nil
        check(ERP.parseTaskDraft(#"{"title":"X","assignee":"null","due":""}"#)?.assignee == nil, "string 'null' -> nil")
        check(ERP.parseTaskDraft(#"{"title":"X","due":""}"#)?.due == nil, "empty due -> nil")

        // body falls back to the title when absent
        check(ERP.parseTaskDraft(#"{"title":"Just this"}"#)?.body == "Just this", "body defaults to title")

        // no title / no object -> nil
        check(ERP.parseTaskDraft(#"{"body":"no title here"}"#) == nil, "missing title -> nil")
        check(ERP.parseTaskDraft("not json at all") == nil, "no object -> nil")

        // long title is shortened (shortTitle, cap ~70 at a word boundary)
        let long = String(repeating: "word ", count: 30)
        check((ERP.parseTaskDraft(#"{"title":"\#(long)"}"#)?.title.count ?? 999) <= 71, "long title shortened")

        // taskDraftPrompt carries the request, context, JSON contract, and today's date
        let p = ERP.taskDraftPrompt(request: "make a task for the bug", context: "### meeting · 2026-11-20 · standup\nfix the bug", today: Date())
        check(p.contains("make a task for the bug") && p.contains("fix the bug"), "prompt has request + context")
        check(p.contains("\"title\"") && p.contains("\"due\""), "prompt states the JSON shape")
        let df = DateFormatter(); df.locale = Locale(identifier: "en_US_POSIX"); df.dateFormat = "yyyy-MM-dd"
        check(p.contains(df.string(from: Date())), "prompt states today")

        print(fails == 0 ? "ALL PASS" : "\(fails) FAILED")
        exit(fails == 0 ? 0 : 1)
    }
}
