import Foundation

/// The "Page (.html)" note: the agent's Markdown laid out as a designed page
/// rather than a converted document. Known sections get their own component
/// (task cards you can tick, decision checks, risk callouts, question cards,
/// people cards, calendar tiles, copyable agent prompts); anything else -- a
/// custom template's own sections -- falls back to plain lists and paragraphs.
///
/// PDF and Word keep NoteExporter.html: AppKit's importer can't do any of this
/// and must not go fetching web fonts.
enum NotePage {

    private enum Block {
        case para(String), bullet(String), task(Bool, String), sub(String), code(String)
    }

    private struct Section {
        let title: String
        var blocks: [Block] = []
        var key: String { title.lowercased() }
        /// Only "None." lines (or nothing at all).
        var isEmpty: Bool {
            blocks.allSatisfy {
                switch $0 {
                case .para(let s), .bullet(let s), .task(_, let s): return NoteExporter.isNone(s)
                default: return false
                }
            }
        }
        /// Items that count: bullets and tasks that aren't "None."
        var count: Int {
            blocks.filter {
                switch $0 {
                case .bullet(let s), .task(_, let s): return !NoteExporter.isNone(s)
                default: return false
                }
            }.count
        }
    }

    // MARK: - Parsing

    private static func parse(_ markdown: String) -> (title: String, sections: [Section]) {
        var title = "", sections: [Section] = [], code: [String]?
        for raw in markdown.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                if let c = code { append(.code(c.joined(separator: "\n"))); code = nil } else { code = [] }
                continue
            }
            if code != nil { code!.append(raw); continue }
            if line.isEmpty || line == "---" { continue }
            if line.hasPrefix("# ") { title = String(line.dropFirst(2)); continue }
            if line.hasPrefix("## ") { sections.append(Section(title: String(line.dropFirst(3)))); continue }
            if line.hasPrefix("###") { append(.sub(line.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces))); continue }
            if line.hasPrefix("- ") || line.hasPrefix("* ") {
                let item = String(line.dropFirst(2))
                if item.hasPrefix("[ ] ") { append(.task(false, String(item.dropFirst(4)))) }
                else if item.lowercased().hasPrefix("[x] ") { append(.task(true, String(item.dropFirst(4)))) }
                else { append(.bullet(item)) }
                continue
            }
            append(.para(line))
        }
        if let c = code { append(.code(c.joined(separator: "\n"))) }
        return (title, sections)

        func append(_ b: Block) {
            if sections.isEmpty { sections.append(Section(title: "Notes")) }
            sections[sections.count - 1].blocks.append(b)
        }
    }

    // MARK: - Page

    static func html(from markdown: String) -> String {
        let (title, sections) = parse(markdown)
        let isMeeting = title.hasPrefix("Meeting")
        func find(_ name: String) -> Section? { sections.first { $0.key == name } }

        // Summary first, then what people act on, then context.
        let order = isMeeting
            ? ["action items", "decisions", "blockers & risks", "open questions", "follow-up meetings", "speakers", "agent prompts"]
            : ["key points", "notable quotes / examples", "open questions"]
        var ordered = order.compactMap(find)
        ordered += sections.filter { !order.contains($0.key) && $0.key != "summary" && $0.key != "per-speaker highlights" }

        var body = "", empty: [String] = [], nav: [String] = []
        for s in ordered {
            let people = s.key == "speakers"
            let highlights = find("per-speaker highlights")
            if s.isEmpty && !(people && highlights.map { !$0.isEmpty } == true) { empty.append(s.title); continue }
            let id = anchor(s.title)
            let label = people ? "People" : s.title
            let n = people ? 0 : s.count
            nav.append("<a href=\"#\(id)\">\(n > 0 ? "<b>\(n)</b> " : "")\(esc(label))</a>")
            body += "<section id=\"\(id)\" class=\"sec\">\n<h2>\(esc(label))\(n > 0 ? " <span class=\"n\">\(n)</span>" : "")</h2>\n"
            switch s.key {
            case "action items": body += tasks(s)
            case "decisions": body += list(s, cls: "decisions")
            case "blockers & risks": body += risks(s)
            case "open questions": body += questions(s)
            case "follow-up meetings": body += followUps(s, noteTitle: title)
            case "speakers": body += peopleCards(s, highlights)
            case "agent prompts": body += prompts(s)
            case "key points": body += list(s, cls: "points")
            case "notable quotes / examples": body += quotes(s)
            default: body += generic(s.blocks)
            }
            body += "</section>\n"
        }
        if !empty.isEmpty {
            body += "<p class=\"empty\">Nothing recorded for \(empty.map(esc).joined(separator: " · ")).</p>\n"
        }

        return """
        <!doctype html>
        <html lang="en"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
        <title>\(esc(title.isEmpty ? "Nikxel note" : title))</title>
        <link rel="preconnect" href="https://fonts.googleapis.com"><link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
        <link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Caveat:wght@600&family=DM+Mono:wght@400;500&family=DM+Sans:opsz,wght@9..40,400;9..40,500;9..40,600;9..40,700;9..40,800&display=swap">
        <style>\(css)</style></head><body>
        <main>
        \(hero(title: title, summary: find("summary"), isMeeting: isMeeting))
        \(nav.count > 1 ? "<nav class=\"glance\">\(nav.joined())</nav>" : "")
        \(body)
        <footer>Written by Nikxel from the recording's transcript. Tick tasks off here; the ticks stay in this browser only.</footer>
        </main>
        <script>\(js)</script>
        </body></html>
        """
    }

    // MARK: - Components

    /// Eyebrow + date, then the summary's opening line as the headline.
    /// Prompts v6+ write that line in bold; older notes have one long
    /// paragraph, so their first sentence is promoted instead.
    private static func hero(title: String, summary: Section?, isMeeting: Bool) -> String {
        let parts = title.components(separatedBy: " — ")
        var kind = isMeeting ? "Minutes of meeting" : (parts.first ?? "Notes")
        if parts.count < 2 { kind = title.isEmpty ? "Note" : title }
        var when = parts.count == 2 ? parts[1] : ""
        let parse = DateFormatter()
        parse.locale = Locale(identifier: "en_US_POSIX")
        parse.dateFormat = "yyyy-MM-dd HH:mm"
        if let d = parse.date(from: when) {
            let f = DateFormatter(); f.dateFormat = "EEEE d MMMM yyyy"
            let t = DateFormatter(); t.timeStyle = .short
            when = "\(f.string(from: d)) · \(t.string(from: d))"
        }

        var paras: [String] = summary?.blocks.compactMap { if case .para(let s) = $0 { return s } else { return nil } } ?? []
        var headline = ""
        if let first = paras.first {
            if first.hasPrefix("**") && first.hasSuffix("**") && first.count > 4 {
                headline = String(first.dropFirst(2).dropLast(2)); paras.removeFirst()
            } else if let r = first.range(of: ". "), first.distance(from: first.startIndex, to: r.lowerBound) < 220 {
                headline = String(first[..<r.lowerBound]) + "."
                paras[0] = String(first[r.upperBound...])
            } else if first.count < 220 {
                headline = first; paras.removeFirst()
            }
        }
        let rest = paras.map { "<p>\(inl($0))</p>" }.joined()
        return """
        <header class="hero">
        <p class="eyebrow"><span>\(esc(kind))</span>\(when.isEmpty ? "" : "<span class=\"when\">\(esc(when))</span>")</p>
        \(headline.isEmpty ? "" : "<p class=\"scribble\" aria-hidden=\"true\">in short</p><h1>\(inl(headline))</h1>")
        \(rest.isEmpty ? "" : "<div class=\"summary\">\(rest)</div>")
        </header>
        """
    }

    private static func tasks(_ s: Section) -> String {
        var out = "<ul class=\"tasks\">\n", i = 0
        for b in s.blocks {
            guard case .task(let done, let item) = b, !NoteExporter.isNone(item) else { continue }
            i += 1
            let (text, fields) = NoteExporter.splitFields(item)
            let chips = fields.map { f -> String in
                let k = f.key.lowercased()
                if k == "owner" && !isUnset(f.value) {
                    return "<span class=\"chip who\">\(avatar(f.value, small: true))\(inl(f.value))</span>"
                }
                if k == "due" && !isUnset(f.value) { return "<span class=\"chip due\">Due \(esc(shortDate(f.value)))</span>" }
                return "<span class=\"chip\(isUnset(f.value) ? " unset" : "")\">\(esc(f.key)) \(inl(f.value))</span>"
            }.joined()
            out += """
            <li class="task"><input type="checkbox" id="task-\(i)"\(done ? " checked" : "")>
            <label for="task-\(i)"><span class="t">\(inl(stripBold(text)))</span>\(chips.isEmpty ? "" : "<span class=\"chips\">\(chips)</span>")</label></li>\n
            """
        }
        return out + "</ul>\n"
    }

    private static func list(_ s: Section, cls: String) -> String {
        "<ul class=\"\(cls)\">" + s.blocks.compactMap { b -> String? in
            guard case .bullet(let t) = b, !NoteExporter.isNone(t) else { return nil }
            return "<li>\(inl(t))</li>"
        }.joined() + "</ul>\n" + extras(s.blocks)
    }

    private static func risks(_ s: Section) -> String {
        "<div class=\"risks\">" + s.blocks.compactMap { b -> String? in
            guard case .bullet(let t) = b, !NoteExporter.isNone(t) else { return nil }
            return "<div class=\"risk\"><span class=\"mark\" aria-hidden=\"true\">!</span><p>\(inl(t))</p></div>"
        }.joined() + "</div>\n" + extras(s.blocks)
    }

    private static func questions(_ s: Section) -> String {
        "<div class=\"questions\">" + s.blocks.compactMap { b -> String? in
            guard case .bullet(let t) = b, !NoteExporter.isNone(t) else { return nil }
            return "<div class=\"q\"><span class=\"mark\" aria-hidden=\"true\">?</span><p>\(inl(t))</p></div>"
        }.joined() + "</div>\n" + extras(s.blocks)
    }

    private static func quotes(_ s: Section) -> String {
        s.blocks.compactMap { b -> String? in
            guard case .bullet(let t) = b, !NoteExporter.isNone(t) else { return nil }
            return "<blockquote>\(inl(t))</blockquote>"
        }.joined() + extras(s.blocks)
    }

    /// Calendar tiles, each with one-click "add to calendar": a pre-filled
    /// Google Calendar event (they just press Save) and an .ics for Apple
    /// Calendar / Outlook. No login, no server -- works from the local file.
    /// Times are local ("floating"), which is what the meeting said.
    private static func followUps(_ s: Section, noteTitle: String) -> String {
        "<div class=\"meets\">" + s.blocks.compactMap { b -> String? in
            guard case .bullet(let item) = b, !NoteExporter.isNone(item) else { return nil }
            let (text, fields) = NoteExporter.splitFields(item)
            var f: [String: String] = [:]
            for x in fields { f[x.key.lowercased()] = x.value }
            let when = f["when"] ?? ""
            var month = "TBD", day = "–", time = ""
            var start: Date?, hasTime = false
            let p = DateFormatter(); p.locale = Locale(identifier: "en_US_POSIX")
            for fmt in ["yyyy-MM-dd HH:mm", "yyyy-MM-dd"] {
                p.dateFormat = fmt
                if let d = p.date(from: when) {
                    start = d; hasTime = fmt.contains("HH")
                    let m = DateFormatter(); m.dateFormat = "MMM"; month = m.string(from: d)
                    let dd = DateFormatter(); dd.dateFormat = "d"; day = dd.string(from: d)
                    if hasTime { let t = DateFormatter(); t.dateFormat = "EEE · HH:mm"; time = t.string(from: d) }
                    else { let t = DateFormatter(); t.dateFormat = "EEEE"; time = t.string(from: d) + " · time not set" }
                    break
                }
            }
            let with = f["with"].flatMap { isUnset($0) ? nil : $0 }
            let meta = [time, f["duration"] ?? "", with.map { "with \($0)" } ?? ""]
                .filter { !$0.isEmpty }.map(esc).joined(separator: " · ")

            let title = plain(stripBold(text))
            let minutes = Int((f["duration"] ?? "").prefix(while: { $0.isNumber })) ?? 30
            let details = (["Agreed in: \(noteTitle)"] + (with.map { ["With: \($0)"] } ?? [])).joined(separator: "\n")
            let links = calendarLinks(title: title, start: start, hasTime: hasTime, minutes: minutes, details: details)
            return """
            <div class="meet"><div class="cal"><span>\(esc(month))</span><b>\(esc(day))</b></div>
            <div class="mb"><p class="mt">\(inl(stripBold(text)))</p><p class="mm">\(meta)</p>
            <div class="add"><a class="btn primary" href="\(esc(links.google))" target="_blank" rel="noopener">Add to Google Calendar</a><a class="btn" href="\(esc(links.ics))" download="\(esc(fileName(title))).ics">Apple / Outlook (.ics)</a></div></div></div>
            """
        }.joined() + "</div>\n"
    }

    /// Google's event template URL and an .ics data URI for the same event.
    /// No date -> Google opens with today (they pick); no time -> all day.
    static func calendarLinks(title: String, start: Date?, hasTime: Bool, minutes: Int, details: String) -> (google: String, ics: String) {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
        var dates = "", dtStart = "", dtEnd = ""
        if let start = start {
            if hasTime {
                f.dateFormat = "yyyyMMdd'T'HHmmss"
                let end = start.addingTimeInterval(Double(max(minutes, 5)) * 60)
                dates = "\(f.string(from: start))/\(f.string(from: end))"
                dtStart = "DTSTART:\(f.string(from: start))"; dtEnd = "DTEND:\(f.string(from: end))"
            } else {
                f.dateFormat = "yyyyMMdd"
                let end = Calendar.current.date(byAdding: .day, value: 1, to: start)!
                dates = "\(f.string(from: start))/\(f.string(from: end))"
                dtStart = "DTSTART;VALUE=DATE:\(f.string(from: start))"; dtEnd = "DTEND;VALUE=DATE:\(f.string(from: end))"
            }
        }
        var c = URLComponents(string: "https://calendar.google.com/calendar/render")!
        c.queryItems = [URLQueryItem(name: "action", value: "TEMPLATE"), URLQueryItem(name: "text", value: title),
                        URLQueryItem(name: "details", value: details)]
            + (dates.isEmpty ? [] : [URLQueryItem(name: "dates", value: dates)])
        let google = c.url?.absoluteString ?? "https://calendar.google.com"

        func icsText(_ s: String) -> String {
            s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: ";", with: "\\;")
                .replacingOccurrences(of: ",", with: "\\,").replacingOccurrences(of: "\n", with: "\\n")
        }
        f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"; f.timeZone = TimeZone(identifier: "UTC")
        let ics = ["BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//Nikxel//Notes//EN", "BEGIN:VEVENT",
                   "UID:\(UUID().uuidString)@nikxel", "DTSTAMP:\(f.string(from: Date()))",
                   dtStart, dtEnd, "SUMMARY:\(icsText(title))", "DESCRIPTION:\(icsText(details))",
                   "END:VEVENT", "END:VCALENDAR"].filter { !$0.isEmpty }.joined(separator: "\r\n")
        let encoded = ics.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        return (google, "data:text/calendar;charset=utf-8,\(encoded)")
    }

    private static func plain(_ s: String) -> String {
        s.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
    }

    private static func fileName(_ s: String) -> String {
        let cleaned = s.map { $0.isLetter || $0.isNumber ? String($0) : " " }.joined()
            .split(separator: " ").joined(separator: "-")
        return cleaned.isEmpty ? "meeting" : String(cleaned.prefix(60))
    }

    /// Speakers (who and why we think so) merged with Per-Speaker Highlights
    /// (what they said) into one card per person.
    private static func peopleCards(_ speakers: Section, _ highlights: Section?) -> String {
        var people: [(name: String, role: String, body: String)] = []
        for b in speakers.blocks {
            guard case .bullet(let t) = b, !NoteExporter.isNone(t) else { continue }
            let (name, role) = splitPerson(t)
            people.append((name, role, ""))
        }
        // Highlights: "**Name**" then bullets, or "**Name:** paragraph".
        var current: Int?
        var bullets: [String] = []
        func flush() {
            guard let i = current, !bullets.isEmpty else { bullets = []; return }
            people[i].body += "<ul>" + bullets.map { "<li>\(inl($0))</li>" }.joined() + "</ul>"
            bullets = []
        }
        for b in highlights?.blocks ?? [] {
            switch b {
            case .para(let t) where t.hasPrefix("**"):
                flush()
                let (name, rest) = splitPerson(t)
                let key = norm(name)
                if let i = people.firstIndex(where: { norm($0.name) == key || norm($0.name).hasPrefix(key) || key.hasPrefix(norm($0.name)) }) {
                    current = i
                } else {
                    people.append((name, "", "")); current = people.count - 1
                }
                if !rest.isEmpty { people[current!].body += "<p>\(inl(rest))</p>" }
            case .bullet(let t): bullets.append(t)
            case .para(let t): if let i = current { people[i].body += "<p>\(inl(t))</p>" }
            default: break
            }
        }
        flush()
        return "<div class=\"people\">" + people.map { p in
            """
            <article class="person"><div class="ph">\(avatar(p.name, small: false))<div><p class="pn">\(inl(p.name))</p>\(p.role.isEmpty ? "" : "<p class=\"pr\">\(inl(p.role))</p>")</div></div>
            \(p.body.isEmpty ? "" : "<div class=\"pb\">\(p.body)</div>")</article>
            """
        }.joined() + "</div>\n"
    }

    private static func prompts(_ s: Section) -> String {
        var out = "", title = ""
        for b in s.blocks {
            switch b {
            case .sub(let t): title = t
            case .code(let c):
                out += """
                <div class="prompt"><div class="prh"><p>\(inl(title.isEmpty ? "Prompt" : title))</p><button type="button" class="copy">Copy</button></div>
                <pre><code>\(esc(c))</code></pre></div>\n
                """
                title = ""
            default: break
            }
        }
        return out.isEmpty ? generic(s.blocks) : out
    }

    /// Paragraphs and stray lines a component didn't consume.
    private static func extras(_ blocks: [Block]) -> String {
        blocks.compactMap { if case .para(let t) = $0, !NoteExporter.isNone(t) { return "<p>\(inl(t))</p>" } else { return nil } }.joined()
    }

    private static func generic(_ blocks: [Block]) -> String {
        var out = "", open = false
        for b in blocks {
            if case .bullet = b {} else if open { out += "</ul>"; open = false }
            switch b {
            case .bullet(let t): if !open { out += "<ul class=\"plain\">"; open = true }; out += "<li>\(inl(t))</li>"
            case .para(let t): out += "<p>\(inl(t))</p>"
            case .task(_, let t): out += "<p>☐ \(inl(t))</p>"
            case .sub(let t): out += "<h3>\(inl(t))</h3>"
            case .code(let c): out += "<pre><code>\(esc(c))</code></pre>"
            }
        }
        return out + (open ? "</ul>" : "") + "\n"
    }

    // MARK: - Helpers

    private static func esc(_ s: String) -> String { NoteExporter.escape(s) }
    private static func inl(_ s: String) -> String { NoteExporter.inline(s) }
    private static func isUnset(_ v: String) -> Bool { ["not specified", "unassigned"].contains(v.lowercased()) }

    private static func stripBold(_ s: String) -> String {
        s.hasPrefix("**") && s.hasSuffix("**") && s.count > 4 ? String(s.dropFirst(2).dropLast(2)) : s
    }

    /// "**Name (Me)** — role", "Name (Me): role", "**Name:** text" -> (name, rest)
    private static func splitPerson(_ t: String) -> (String, String) {
        if t.hasPrefix("**"), let end = t.range(of: "**", range: t.index(t.startIndex, offsetBy: 2)..<t.endIndex) {
            var name = String(t[t.index(t.startIndex, offsetBy: 2)..<end.lowerBound]).trimmingCharacters(in: .whitespaces)
            if name.hasSuffix(":") { name.removeLast() }
            var rest = String(t[end.upperBound...]).trimmingCharacters(in: .whitespaces)
            for p in ["—", ":", "-"] where rest.hasPrefix(p) { rest = String(rest.dropFirst(p.count)).trimmingCharacters(in: .whitespaces) }
            return (name, rest)
        }
        for sep in [" — ", ": "] {
            if let r = t.range(of: sep) { return (String(t[..<r.lowerBound]), String(t[r.upperBound...])) }
        }
        return (t, "")
    }

    private static func norm(_ s: String) -> String {
        s.lowercased().replacingOccurrences(of: "*", with: "").components(separatedBy: " (").first!
            .trimmingCharacters(in: .whitespaces)
    }

    /// Initials on one of five pastel grounds, picked by the name so a person
    /// keeps their colour across the page.
    private static func avatar(_ name: String, small: Bool) -> String {
        let clean = norm(name)
        let words = clean.split(separator: " ").filter { $0.first?.isLetter == true }
        let initials = words.prefix(2).compactMap { $0.first.map(String.init) }.joined().uppercased()
        let tone = clean.unicodeScalars.reduce(0) { $0 + Int($1.value) } % 5
        return "<span class=\"av t\(tone)\(small ? " sm" : "")\" aria-hidden=\"true\">\(esc(initials.isEmpty ? "?" : initials))</span>"
    }

    private static func shortDate(_ v: String) -> String {
        let p = DateFormatter(); p.locale = Locale(identifier: "en_US_POSIX"); p.dateFormat = "yyyy-MM-dd"
        guard let d = p.date(from: v) else { return v }
        let f = DateFormatter(); f.dateFormat = "EEE d MMM"
        return f.string(from: d)
    }

    private static func anchor(_ s: String) -> String {
        s.lowercased().map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
            .split(separator: "-").joined(separator: "-")
    }

    // MARK: - Style

    // Layout: one reading column; the hero states the takeaway, components
    // below are shaped by what each section is for. Brand palette from the
    // website (paper green, ink, green accent, pastel grounds).
    private static let css = """
    :root {
      --bg: #f6faf5; --surface: #ffffff; --ink: #25302a; --muted: #5c6a60; --faint: #8a968d; --line: #d7e9d6;
      --accent: #23864d; --mint: #d6f3e3; --butter: #fff3c4; --lilac: #e8ddff; --peach: #ffe6d3; --sky: #e1eeff;
      --warn-ink: #8a4a1c; --code-bg: #1f2823; --code-ink: #dfeee3;
      --sans: "DM Sans", -apple-system, "Helvetica Neue", Helvetica, sans-serif;
      --hand: "Caveat", "Bradley Hand", "Segoe Print", cursive;
      --mono: "DM Mono", ui-monospace, "SF Mono", Menlo, monospace;
    }
    @media (prefers-color-scheme: dark) { :root:not([data-theme="light"]) {
      --bg: #111613; --surface: #181f1b; --ink: #e4efe7; --muted: #9eaca2; --faint: #74827a; --line: #26322b;
      --accent: #6fd396; --mint: #1d3a2a; --butter: #3a3320; --lilac: #2c2640; --peach: #3c2a1f; --sky: #1c2a3c;
      --warn-ink: #ffc8a6; --code-bg: #0c100e; --code-ink: #dfeee3; color-scheme: dark; } }
    :root[data-theme="dark"] {
      --bg: #111613; --surface: #181f1b; --ink: #e4efe7; --muted: #9eaca2; --faint: #74827a; --line: #26322b;
      --accent: #6fd396; --mint: #1d3a2a; --butter: #3a3320; --lilac: #2c2640; --peach: #3c2a1f; --sky: #1c2a3c;
      --warn-ink: #ffc8a6; --code-bg: #0c100e; --code-ink: #dfeee3; color-scheme: dark; }
    * { box-sizing: border-box; }
    body { margin: 0; background: var(--bg); color: var(--ink); font: 400 16px/1.6 var(--sans); -webkit-font-smoothing: antialiased; }
    main { max-width: 780px; margin: 0 auto; padding-block: 56px 72px; padding-left: max(20px, env(safe-area-inset-left, 0px)); padding-right: max(20px, env(safe-area-inset-right, 0px)); }
    p { margin: 0; }
    b, strong { font-weight: 650; }
    code { font-family: var(--mono); font-size: .86em; background: var(--mint); padding: 1px 5px; border-radius: 5px; }

    .hero { display: grid; gap: 14px; padding-bottom: 28px; }
    .eyebrow { display: flex; flex-wrap: wrap; gap: 6px 14px; font: 500 12px/1.4 var(--mono); letter-spacing: .06em; text-transform: uppercase; color: var(--accent); }
    .eyebrow .when { color: var(--muted); }
    .scribble { font: 600 26px/1 var(--hand); color: var(--accent); transform: rotate(-3deg); transform-origin: left; margin: 18px 0 -6px; }
    h1 { margin: 0; font: 750 clamp(27px, 4.4vw, 38px)/1.16 var(--sans); letter-spacing: -.02em; text-wrap: balance; }
    .summary { display: grid; gap: 10px; max-width: 64ch; color: var(--muted); font-size: 16.5px; }

    .glance { display: flex; flex-wrap: wrap; gap: 8px; padding: 18px 0; border-block: 1px solid var(--line); }
    .glance a { font: 400 13px/1 var(--mono); color: var(--muted); text-decoration: none; background: var(--surface); border: 1px solid var(--line); border-radius: 99px; padding: 8px 12px; }
    .glance a:hover, .glance a:focus-visible { border-color: var(--accent); color: var(--ink); outline: none; }
    .glance b { font-weight: 500; color: var(--accent); font-variant-numeric: tabular-nums; }
    .sec { padding-top: 44px; display: grid; gap: 16px; }
    h2 { margin: 0; display: flex; align-items: baseline; gap: 10px; font: 700 13px/1.2 var(--sans); letter-spacing: .09em; text-transform: uppercase; color: var(--ink); }
    h2 .n { font: 500 12px/1 var(--mono); color: var(--accent); background: var(--mint); border-radius: 99px; padding: 4px 8px; letter-spacing: 0; }
    h3 { margin: 8px 0 0; font-size: 16px; }

    ul { margin: 0; padding: 0; list-style: none; }
    .tasks { display: grid; gap: 10px; }
    .task { display: flex; gap: 14px; align-items: flex-start; background: var(--surface); border: 1px solid var(--line); border-radius: 14px; padding: 16px 18px; transition: opacity .2s, transform .2s; }
    .task:hover { transform: translateY(-1px); }
    .task input { appearance: none; flex: none; width: 22px; height: 22px; margin: 1px 0 0; border: 2px solid var(--accent); border-radius: 7px; cursor: pointer; display: grid; place-content: center; background: var(--surface); }
    .task input::after { content: ""; width: 10px; height: 6px; border: solid var(--surface); border-width: 0 0 2.5px 2.5px; transform: rotate(-45deg) translate(1px, -1px); opacity: 0; }
    .task input:checked { background: var(--accent); }
    .task input:checked::after { opacity: 1; }
    .task input:focus-visible { outline: 3px solid var(--mint); outline-offset: 2px; }
    .task label { display: grid; gap: 10px; min-width: 0; cursor: pointer; }
    .task .t { font-weight: 600; line-height: 1.45; }
    .task:has(input:checked) { opacity: .55; }
    .task:has(input:checked) .t { text-decoration: line-through; text-decoration-color: var(--faint); }
    .chips { display: flex; flex-wrap: wrap; gap: 6px; }
    .chip { display: inline-flex; align-items: center; gap: 6px; font: 500 12.5px/1 var(--sans); background: var(--mint); border-radius: 99px; padding: 4px 10px 4px 10px; }
    .chip.who { padding-left: 3px; }
    .chip.due { background: var(--butter); font-family: var(--mono); font-size: 12px; }
    .chip.unset { background: transparent; border: 1px dashed var(--line); color: var(--faint); }

    .decisions { display: grid; gap: 10px; }
    .decisions li { position: relative; padding-left: 34px; font-weight: 500; }
    .decisions li::before { content: "✓"; position: absolute; left: 0; top: 1px; width: 22px; height: 22px; border-radius: 50%; background: var(--accent); color: var(--surface); font: 700 13px/22px var(--sans); text-align: center; }

    .risks { display: grid; gap: 10px; }
    .risk { display: flex; gap: 12px; align-items: flex-start; background: var(--peach); border-radius: 14px; padding: 14px 16px; }
    .risk .mark { flex: none; width: 22px; height: 22px; border-radius: 50%; border: 2px solid var(--warn-ink); color: var(--warn-ink); font: 700 13px/18px var(--sans); text-align: center; margin-top: 1px; }
    .risk p { min-width: 0; }

    .questions { display: grid; grid-template-columns: repeat(auto-fit, minmax(min(100%, 300px), 1fr)); gap: 10px; }
    .q { display: flex; gap: 10px; background: var(--lilac); border-radius: 14px; padding: 14px 16px; }
    .q .mark { flex: none; font: 600 30px/0.9 var(--hand); color: var(--accent); }
    .q p { min-width: 0; }

    .points { display: grid; gap: 12px; }
    .points li { position: relative; padding-left: 22px; }
    .points li::before { content: ""; position: absolute; left: 2px; top: .62em; width: 8px; height: 8px; border-radius: 50%; background: var(--accent); }
    .plain { display: grid; gap: 8px; padding-left: 20px; list-style: disc; }
    blockquote { margin: 0; padding: 4px 0 4px 44px; position: relative; font-size: 18px; line-height: 1.5; }
    blockquote::before { content: "\\201C"; position: absolute; left: 0; top: -10px; font: 600 64px/1 var(--hand); color: var(--accent); }

    .meets { display: grid; gap: 10px; }
    .meet { display: flex; gap: 16px; align-items: flex-start; background: var(--surface); border: 1px solid var(--line); border-radius: 14px; padding: 12px 16px; }
    .cal { flex: none; width: 58px; border-radius: 10px; overflow: hidden; text-align: center; background: var(--sky); }
    .cal span { display: block; background: var(--accent); color: var(--surface); font: 600 11px/1.9 var(--mono); text-transform: uppercase; letter-spacing: .08em; }
    .cal b { display: block; font: 700 24px/1.6 var(--sans); }
    .mb { display: grid; gap: 2px; min-width: 0; }
    .mt { font-weight: 600; }
    .add { display: flex; flex-wrap: wrap; gap: 8px; margin-top: 10px; }
    .btn { font: 600 13px/1 var(--sans); color: var(--ink); text-decoration: none; border: 1px solid var(--line); background: var(--surface); border-radius: 10px; padding: 9px 12px; }
    .btn.primary { background: var(--accent); border-color: var(--accent); color: var(--surface); }
    .btn:hover { transform: translateY(-1px); }
    .btn:focus-visible { outline: 3px solid var(--mint); outline-offset: 2px; }
    .mm { color: var(--muted); font-size: 14px; }

    .people { display: grid; grid-template-columns: repeat(auto-fit, minmax(min(100%, 320px), 1fr)); gap: 12px; }
    .person { background: var(--surface); border: 1px solid var(--line); border-radius: 16px; padding: 18px; display: grid; gap: 12px; align-content: start; min-width: 0; }
    .ph { display: flex; gap: 12px; align-items: flex-start; }
    .ph > div { min-width: 0; padding-top: 2px; }
    .pn { font-weight: 700; }
    .pr { color: var(--muted); font-size: 13.5px; line-height: 1.45; }
    .pb { display: grid; gap: 8px; font-size: 15px; }
    .pb ul { display: grid; gap: 6px; }
    .pb li { position: relative; padding-left: 16px; }
    .pb li::before { content: ""; position: absolute; left: 0; top: .7em; width: 6px; height: 2px; background: var(--faint); }
    .av { flex: none; width: 40px; height: 40px; border-radius: 50%; display: grid; place-content: center; font: 700 14px/1 var(--sans); color: var(--ink); }
    .av.sm { width: 20px; height: 20px; font-size: 9px; }
    .t0 { background: var(--mint); } .t1 { background: var(--butter); } .t2 { background: var(--lilac); } .t3 { background: var(--peach); } .t4 { background: var(--sky); }
    .chip .av { background: var(--surface); }

    .prompt { border-radius: 14px; overflow: hidden; background: var(--code-bg); }
    .prh { display: flex; justify-content: space-between; align-items: center; gap: 12px; padding: 10px 12px 10px 16px; color: var(--code-ink); font-weight: 600; font-size: 14px; border-bottom: 1px solid rgba(255,255,255,.08); }
    .copy { font: 500 12px/1 var(--mono); color: var(--code-ink); background: rgba(255,255,255,.08); border: 1px solid rgba(255,255,255,.14); border-radius: 8px; padding: 7px 10px; cursor: pointer; }
    .copy:hover, .copy:focus-visible { background: rgba(255,255,255,.16); outline: none; }
    pre { margin: 0; padding: 14px 16px; overflow-x: auto; color: var(--code-ink); font: 400 13px/1.6 var(--mono); white-space: pre-wrap; }
    pre code { background: none; padding: 0; font-size: inherit; color: inherit; }

    .empty { margin-top: 44px; padding-top: 18px; border-top: 1px dashed var(--line); color: var(--faint); font-size: 14px; }
    footer { margin-top: 28px; color: var(--faint); font-size: 12.5px; }

    @media (prefers-reduced-motion: no-preference) {
      .hero, .glance, .sec { animation: rise .5s cubic-bezier(.2,.7,.2,1) both; }
      .glance { animation-delay: .06s; }
      .sec:nth-of-type(1) { animation-delay: .14s; } .sec:nth-of-type(2) { animation-delay: .18s; } .sec:nth-of-type(3) { animation-delay: .22s; }
      @keyframes rise { from { transform: translateY(8px); } to { transform: none; } }
    }
    @media print {
      body { background: #fff; } .glance, .copy, .add, footer, .scribble { display: none; }
      .sec { break-inside: avoid; } .task, .person, .meet { border-color: #ccc; }
    }
    """

    /// Ticks persist per note in this browser; Copy on agent prompts.
    private static let js = """
    (function () {
      var key = "nikxel:" + location.pathname;
      var saved = {};
      try { saved = JSON.parse(localStorage.getItem(key) || "{}"); } catch (e) {}
      document.querySelectorAll(".task input").forEach(function (box) {
        if (box.id in saved) box.checked = saved[box.id];
        box.addEventListener("change", function () {
          saved[box.id] = box.checked;
          try { localStorage.setItem(key, JSON.stringify(saved)); } catch (e) {}
        });
      });
      document.querySelectorAll(".copy").forEach(function (btn) {
        btn.addEventListener("click", function () {
          var code = btn.closest(".prompt").querySelector("code");
          var done = function () { btn.textContent = "Copied"; setTimeout(function () { btn.textContent = "Copy"; }, 1600); };
          var select = function () { var r = document.createRange(); r.selectNodeContents(code); var s = getSelection(); s.removeAllRanges(); s.addRange(r); };
          if (navigator.clipboard) navigator.clipboard.writeText(code.textContent).then(done, select); else select();
        });
      });
    })();
    """
}
