// swiftc src/Automation.swift checks/check_automation.swift -o /tmp/cau && /tmp/cau
import Foundation

@main struct CheckAutomation {
    static func main() throws {
        var fails = 0
        func check(_ ok: Bool, _ what: String) { if !ok { fails += 1; print("FAIL: \(what)") } else { print("ok: \(what)") } }
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        func at(_ s: String) -> Date { let f = ISO8601DateFormatter(); return f.date(from: s)! }
        // 2026-11-27 is a Friday.
        let fri9 = at("2026-11-27T09:00:00Z"), sat9 = at("2026-11-28T09:00:00Z")
        var a = Automation(id: "x", name: "Brief", trigger: "schedule", time: "09:00", days: "weekdays", instruction: "Brief me")
        check(a.due(at: fri9, calendar: cal) && !a.due(at: sat9, calendar: cal), "weekdays: Friday yes, Saturday no")
        check(!a.due(at: at("2026-11-27T09:01:00Z"), calendar: cal), "only in its minute")
        a.days = "fri"; check(a.due(at: fri9, calendar: cal), "named weekday")
        a.enabled = false; check(!a.due(at: fri9, calendar: cal), "disabled never runs")
        a.enabled = true; a.trigger = "meeting"; check(!a.due(at: fri9, calendar: cal), "event triggers aren't scheduled")

        let bad = Automation.clean(Automation(id: "", name: "", trigger: "hourly", time: "25:99", days: "someday", instruction: "  Do it  "))
        check(bad?.trigger == "schedule" && bad?.time == "09:00" && bad?.days == "daily" && bad?.name == "Do it" && bad?.id.isEmpty == false, "clean fixes trigger, time, days, name, id")
        check(Automation.clean(Automation(id: "", name: "x", trigger: "day", instruction: " ")) == nil, "no instruction, no automation")
        check(Automation.clean(Automation(id: "", name: "x", trigger: "schedule", time: "7:5", instruction: "y"))?.time == "07:05", "time padded")

        let one = Automation.parse("Sure! {\"name\":\"Follow up\",\"trigger\":\"meeting\",\"instruction\":\"Draft it\"} done")
        check(one.count == 1 && one[0].0.trigger == "meeting", "one object out of prose")
        let many = Automation.parse("```json\n[{\"name\":\"A\",\"trigger\":\"schedule\",\"time\":\"17:00\",\"days\":\"Fri\",\"instruction\":\"x\",\"why\":\"Fridays\"},{\"name\":\"B\",\"instruction\":\"\"}]\n```")
        check(many.count == 1 && many[0].0.days == "fri" && many[0].why == "Fridays", "array, empty one dropped, days lowercased")
        check(Automation.parse("no json here").isEmpty, "nothing to parse")
        check(Automation.ideas.allSatisfy { Automation.clean($0) != nil }, "every idea is valid")
        check(Automation(id: "", name: "", trigger: "schedule", time: "17:00", days: "fri", instruction: "").when == "Every Friday at 17:00", "when label")

        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("au-\(UUID().uuidString).json")
        Automation.file = tmp
        Automation.save([a])
        check(Automation.load() == [a], "saved and loaded")
        try? FileManager.default.removeItem(at: tmp)

        print(fails == 0 ? "ALL OK" : "\(fails) FAILED"); exit(fails == 0 ? 0 : 1)
    }
}
