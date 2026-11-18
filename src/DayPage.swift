import Foundation

/// The end-of-day summary as a page: the meeting note's sibling, but dusk
/// instead of daylight (it lands at 10pm). A night-sky header with the day's
/// takeaway, the day's numbers as tiles, the work as a timeline, meetings as
/// cards, chat tasks with a done/open status, and the lighter sections side
/// by side. Unknown sections fall back to NotePage's generic layout.
/// The Sunday week in review uses the same page at sunrise (`morning`).
enum DayPage {

    /// "… — open" / "… — done." at the end of a bullet, as the prompt asks for chat tasks.
    private static let status = try! NSRegularExpression(pattern: "\\s+[—–-]\\s*(done|open|unclear)\\.?\\s*$", options: .caseInsensitive)
    /// "10:30 — …", "**00:13**: …", "**10:31, Standup**:" at the start of a meeting bullet.
    private static let leadTime = try! NSRegularExpression(pattern: "^(\\*\\*)?(~?\\d{1,2}(?::\\d{2})?\\s?(?:am|pm)?)(\\*\\*)?\\s*[,—–:-]\\s*", options: .caseInsensitive)

    /// A bullet and the bullets indented under it. NotePage.parse flattens
    /// nesting, and day summaries group details under a project or meeting.
    private final class Item {
        let text: String
        var kids: [Item] = []
        init(_ text: String) { self.text = text }
    }

    private static func tree(_ markdown: String, key: String) -> [Item] {
        var roots: [Item] = [], stack: [(indent: Int, item: Item)] = [], inside = false
        for raw in markdown.components(separatedBy: .newlines) {
            if raw.hasPrefix("## ") {
                inside = raw.dropFirst(3).trimmingCharacters(in: .whitespaces).lowercased() == key
                stack.removeAll(); continue
            }
            guard inside else { continue }
            let indent = raw.prefix(while: { $0 == " " || $0 == "\t" }).reduce(0) { $0 + ($1 == "\t" ? 2 : 1) }
            let line = raw.dropFirst(raw.prefix(while: { $0 == " " || $0 == "\t" }).count)
            guard line.hasPrefix("- ") || line.hasPrefix("* ") else { continue }
            let text = line.dropFirst(2).trimmingCharacters(in: .whitespaces)
            if NoteExporter.isNone(text) { continue }
            let item = Item(text)
            while let last = stack.last, last.indent >= indent { stack.removeLast() }
            if let parent = stack.last?.item { parent.kids.append(item) } else { roots.append(item) }
            stack.append((indent, item))
        }
        return roots
    }

    static func html(from markdown: String, stats: DayLogger.DayStats? = nil, morning: Bool = false) -> String {
        let (title, sections) = NotePage.parse(markdown)
        var body = "", empty: [String] = [], side: [NotePage.Section] = []
        for s in sections where s.key != "summary" {
            if s.isEmpty { empty.append(s.title); continue }
            if s.key == "browsing & reading" || s.key == "other" { side.append(s); continue }
            let items = tree(markdown, key: s.key)
            switch s.key {
            case "what you worked on": body += section(s, items.count, timeline(items) + paras(s))
            case "meetings": body += section(s, items.count, meetings(items) + paras(s))
            case "whatsapp", "slack", "open tasks": body += section(s, items.count, statusList(items) + paras(s))
            default: body += section(s, s.count, NotePage.generic(s.blocks))
            }
        }
        if !side.isEmpty {
            body += "<div class=\"pair\">" + side.map {
                "<section id=\"\(NotePage.anchor($0.title))\" class=\"sec panel\"><h2>\(esc($0.title))</h2>\(NotePage.generic($0.blocks))</section>"
            }.joined() + "</div>\n"
        }
        if !empty.isEmpty { body += "<p class=\"empty\">Quiet on \(empty.map(esc).joined(separator: " · ")).</p>\n" }

        return """
        <!doctype html>
        <html lang="en"><head><meta charset="utf-8">\(NoteExporter.favicon)
        <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
        <title>\(esc(title.isEmpty ? (morning ? "Week in review" : "Day in review") : title))</title>
        <link rel="preconnect" href="https://fonts.googleapis.com"><link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
        <link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=DM+Mono:wght@400;500&family=DM+Sans:opsz,wght@9..40,400;9..40,500;9..40,600;9..40,700&family=Fraunces:opsz,wght@9..144,500;9..144,600;9..144,800;9..144,900&display=swap">
        <style>\(css)\(morning ? morningCSS : "")</style></head><body>
        <main>
        \(hero(title: title, summary: sections.first { $0.key == "summary" }, morning: morning))
        \(stats.map(tiles) ?? "")
        \(body)
        <footer>Written by Nikxel from \(morning ? "this week's daily summaries" : "today's activity") on this computer. Nothing here left it.</footer>
        </main>
        \(PageShare.widget(editable: PageEdit.daysEditable))</body></html>
        """
    }

    private static func section(_ s: NotePage.Section, _ n: Int, _ inner: String) -> String {
        return "<section id=\"\(NotePage.anchor(s.title))\" class=\"sec\">\n<h2>\(esc(s.title))\(n > 0 ? " <span class=\"n\">\(n)</span>" : "")</h2>\n\(inner)</section>\n"
    }

    /// "2026-11-12 — Day in review" -> the date large, the takeaway beneath it.
    /// A week's title carries the Sunday it was written; the week shown is
    /// the seven days before it.
    private static func hero(title: String, summary: NotePage.Section?, morning: Bool) -> String {
        let parts = title.components(separatedBy: " — ")
        let p = DateFormatter(); p.locale = Locale(identifier: "en_US_POSIX"); p.dateFormat = "yyyy-MM-dd"
        let d = p.date(from: parts[0])
        var date = title.isEmpty ? (morning ? "This week" : "Today") : title, year = ""
        var kind = morning ? "Week in review" : "Day in review"
        if let d = d {
            let f = DateFormatter(); f.dateFormat = "EEEE, d MMMM"; date = f.string(from: d)
            if morning, let from = Calendar.current.date(byAdding: .day, value: -7, to: d),
               let to = Calendar.current.date(byAdding: .day, value: -1, to: d) {
                let a = DateFormatter(); a.dateFormat = "d MMM"
                date = "\(a.string(from: from)) – \(a.string(from: to))"
            }
            let y = DateFormatter(); y.dateFormat = "yyyy"; year = y.string(from: d)
            if parts.count > 1 { kind = parts[1] }
        }
        let (headline, paras) = NotePage.lead(summary)
        return """
        <header class="sky">
        <div class="\(morning ? "sun" : "moon")" aria-hidden="true"></div>
        <p class="eyebrow"><span>\(esc(kind))</span>\(year.isEmpty ? "" : "<span class=\"yr\">\(year)</span>")</p>
        <p class="date">\(esc(date))</p>
        \(headline.isEmpty ? "" : "<h1>\(inl(headline))</h1>")
        </header>
        \(paras.isEmpty ? "" : "<div class=\"summary\">\(paras.map { "<p>\(inl($0))</p>" }.joined())</div>")
        """
    }

    /// The digest numbers. Zero tiles are left out rather than shown as "0".
    private static func tiles(_ s: DayLogger.DayStats) -> String {
        var items: [(String, String)] = []
        let coding = Int((s.codingSeconds / 60).rounded()), active = Int((s.activeSeconds / 60).rounded())
        if coding >= 1 { items.append((DayLogger.humanDuration(minutes: coding), "coding")) }
        if active >= 1 { items.append((DayLogger.humanDuration(minutes: active), "at the computer")) }
        if s.meetings > 0 { items.append(("\(s.meetings)", s.meetings == 1 ? "meeting" : "meetings")) }
        if s.messages > 0 { items.append(("\(s.messages)", s.messages == 1 ? "message" : "messages")) }
        if items.isEmpty { return "" }
        return "<div class=\"tiles\">" + items.map { "<div class=\"tile\"><b>\(esc($0.0))</b><span>\(esc($0.1))</span></div>" }.joined() + "</div>\n"
    }

    private static func paras(_ s: NotePage.Section) -> String {
        s.blocks.compactMap { if case .para(let t) = $0, !NoteExporter.isNone(t) { return "<p>\(inl(t))</p>" } else { return nil } }.joined()
    }

    private static func kids(_ items: [Item]) -> String {
        items.isEmpty ? "" : "<ul class=\"kids\">" + items.map { "<li>\(withStatus($0.text))\(kids($0.kids))</li>" }.joined() + "</ul>"
    }

    private static func timeline(_ items: [Item]) -> String {
        "<ol class=\"line\">" + items.map { "<li>\(withStatus($0.text))\(kids($0.kids))</li>" }.joined() + "</ol>\n"
    }

    private static func meetings(_ items: [Item]) -> String {
        "<div class=\"meets\">" + items.map { i -> String in
            let ns = i.text as NSString
            guard let m = leadTime.firstMatch(in: i.text, range: NSRange(location: 0, length: ns.length)) else {
                return "<div class=\"meet\"><div class=\"mb\"><p>\(inl(i.text))</p>\(kids(i.kids))</div></div>"
            }
            // "**10:31, Standup**:" -> the time leaves the bold, the title keeps it.
            let reopen = m.range(at: 1).location != NSNotFound && m.range(at: 3).location == NSNotFound
            let rest = (reopen ? "**" : "") + ns.substring(from: m.range.upperBound)
            let time = ns.substring(with: m.range(at: 2)).trimmingCharacters(in: .whitespaces)
            return "<div class=\"meet\"><span class=\"tm\">\(esc(time))</span><div class=\"mb\"><p>\(inl(rest))</p>\(kids(i.kids))</div></div>"
        }.joined() + "</div>\n"
    }

    private static func statusList(_ items: [Item]) -> String {
        "<ul class=\"chat\">" + items.map { "<li>\(withStatus($0.text))\(kids($0.kids))</li>" }.joined() + "</ul>\n"
    }

    /// A trailing "— open" becomes a pill; everything else stays as written.
    private static func withStatus(_ t: String) -> String {
        let ns = t as NSString
        guard let m = status.firstMatch(in: t, range: NSRange(location: 0, length: ns.length)) else { return inl(t) }
        let st = ns.substring(with: m.range(at: 1)).lowercased()
        return "\(inl(ns.substring(to: m.range.location))) <span class=\"st \(st)\">\(st)</span>"
    }

    private static func esc(_ s: String) -> String { NoteExporter.escape(s) }
    private static func inl(_ s: String) -> String { NoteExporter.inline(s) }

    // Sunrise over the dusk sheet: peach-to-sky header with a sun, warm paper
    // and terracotta ink by day; a dawn plum by night. Only the tokens and the
    // header change, so both pages keep one layout.
    private static let morningCSS = """
    :root {
      --bg: #fbf6ee; --surface: #fffdf9; --ink: #2d2118; --muted: #6e5b4b; --faint: #a8968a; --line: #efe3d3;
      --accent: #c2531f; --lamp: #d9891a; --lamp-soft: #fdecd0; --indigo-soft: #fbe6d6; --sage: #e2f0e2; --rose: #fbe3e2;
      --sky-a: #ffcf9a; --sky-b: #9fd2f0; --sky-ink: #2d2118; --sky-muted: #7a5a3f;
    }
    @media (prefers-color-scheme: dark) { :root:not([data-theme="light"]) {
      --bg: #17110d; --surface: #211913; --ink: #f5ebe1; --muted: #c4b2a2; --faint: #8a7768; --line: #3a2c22;
      --accent: #ff9a5c; --lamp: #f5b54a; --lamp-soft: #3d2c17; --indigo-soft: #33241a; --sage: #1c3326; --rose: #3d2228;
      --sky-a: #5b2e3c; --sky-b: #d0773f; --sky-ink: #fff4e8; --sky-muted: #f2c9a4; color-scheme: dark; } }
    :root[data-theme="dark"] {
      --bg: #17110d; --surface: #211913; --ink: #f5ebe1; --muted: #c4b2a2; --faint: #8a7768; --line: #3a2c22;
      --accent: #ff9a5c; --lamp: #f5b54a; --lamp-soft: #3d2c17; --indigo-soft: #33241a; --sage: #1c3326; --rose: #3d2228;
      --sky-a: #5b2e3c; --sky-b: #d0773f; --sky-ink: #fff4e8; --sky-muted: #f2c9a4; color-scheme: dark; }
    .sky { background: linear-gradient(200deg, var(--sky-b) 0%, var(--sky-a) 100%); }
    .sun { position: absolute; top: 22px; right: 26px; width: 56px; height: 56px; border-radius: 50%;
      background: radial-gradient(circle, #fff6d8 0 38%, #ffd36b 60%, #ffb347 100%);
      box-shadow: 0 0 0 10px rgba(255, 214, 120, .28), 0 0 44px 18px rgba(255, 190, 90, .45); }
    .date { font-weight: 900; letter-spacing: -.025em; }
    h1 { font-weight: 600; }
    h2 { font-weight: 800; letter-spacing: -.01em; }
    @media print { .sun { display: none; } }
    """

    // Dusk palette: warm paper and indigo ink by day, deep indigo with lamp-amber
    // by night. Fraunces for the date and headline sets it apart from the
    // meeting page's all-sans look.
    private static let css = """
    :root {
      --bg: #f7f4ee; --surface: #fffdf8; --ink: #1f2140; --muted: #5d5f7a; --faint: #9496ad; --line: #e6e1ef;
      --accent: #4b46b8; --lamp: #c9821c; --lamp-soft: #fdeccb; --indigo-soft: #e7e6fb; --sage: #e1f0e4; --rose: #fbe3e6;
      --sky-a: #2b2a6b; --sky-b: #5a4a9c; --sky-ink: #f4f1ff; --sky-muted: #c9c3ee;
      --serif: "Fraunces", Georgia, "Cambria", serif;
      --sans: "DM Sans", "Segoe UI", -apple-system, "Helvetica Neue", sans-serif;
      --mono: "DM Mono", "Cascadia Mono", Consolas, ui-monospace, Menlo, monospace;
    }
    @media (prefers-color-scheme: dark) { :root:not([data-theme="light"]) {
      --bg: #0f1024; --surface: #171936; --ink: #e9e8f6; --muted: #a4a6c4; --faint: #6f7194; --line: #262955;
      --accent: #a9a5ff; --lamp: #f2b85a; --lamp-soft: #3a2f1a; --indigo-soft: #23255a; --sage: #1c3326; --rose: #3d2230;
      --sky-a: #1a1a46; --sky-b: #3a2f6e; color-scheme: dark; } }
    :root[data-theme="dark"] {
      --bg: #0f1024; --surface: #171936; --ink: #e9e8f6; --muted: #a4a6c4; --faint: #6f7194; --line: #262955;
      --accent: #a9a5ff; --lamp: #f2b85a; --lamp-soft: #3a2f1a; --indigo-soft: #23255a; --sage: #1c3326; --rose: #3d2230;
      --sky-a: #1a1a46; --sky-b: #3a2f6e; color-scheme: dark; }
    * { box-sizing: border-box; }
    body { margin: 0; background: var(--bg); color: var(--ink); font: 400 16px/1.6 var(--sans); -webkit-font-smoothing: antialiased; }
    main { max-width: 760px; margin: 0 auto; padding-block: 40px 72px; padding-left: max(16px, env(safe-area-inset-left, 0px)); padding-right: max(16px, env(safe-area-inset-right, 0px)); }
    p { margin: 0; }
    b, strong { font-weight: 650; }
    code { font-family: var(--mono); font-size: .86em; background: var(--indigo-soft); padding: 1px 5px; border-radius: 5px; }

    .sky { position: relative; overflow: hidden; display: grid; gap: 10px; padding: 34px 32px 32px; border-radius: 24px; color: var(--sky-ink);
      background: radial-gradient(circle at 20% 30%, rgba(255,255,255,.5) 0 1px, transparent 1.5px) 0 0 / 90px 70px,
                  radial-gradient(circle at 70% 60%, rgba(255,255,255,.35) 0 1px, transparent 1.5px) 0 0 / 130px 110px,
                  linear-gradient(160deg, var(--sky-a), var(--sky-b)); }
    .moon { position: absolute; top: 26px; right: 30px; width: 46px; height: 46px; border-radius: 50%; box-shadow: -12px 4px 0 0 #f6d58c; transform: rotate(-20deg); }
    .eyebrow { display: flex; gap: 12px; font: 500 12px/1.4 var(--mono); letter-spacing: .08em; text-transform: uppercase; color: var(--sky-muted); }
    .date { font: 600 clamp(30px, 6vw, 46px)/1.05 var(--serif); letter-spacing: -.01em; }
    h1 { margin: 8px 0 0; max-width: 34ch; font: 500 clamp(18px, 2.6vw, 21px)/1.45 var(--serif); color: var(--sky-ink); text-wrap: pretty; }
    .summary { display: grid; gap: 10px; padding: 22px 4px 0; color: var(--muted); font-size: 16.5px; max-width: 64ch; }

    .tiles { display: grid; grid-template-columns: repeat(auto-fit, minmax(140px, 1fr)); gap: 10px; margin-top: 22px; }
    .tile { display: grid; gap: 2px; background: var(--surface); border: 1px solid var(--line); border-radius: 16px; padding: 14px 16px; }
    .tile b { font: 500 24px/1.2 var(--mono); color: var(--accent); font-variant-numeric: tabular-nums; }
    .tile span { color: var(--muted); font-size: 13.5px; }

    .sec { padding-top: 40px; display: grid; gap: 14px; }
    h2 { margin: 0; display: flex; align-items: baseline; gap: 10px; font: 600 22px/1.2 var(--serif); }
    h2 .n { font: 500 12px/1 var(--mono); color: var(--lamp); background: var(--lamp-soft); border-radius: 99px; padding: 4px 8px; }
    h3 { margin: 8px 0 0; font-size: 16px; }
    ul, ol { margin: 0; padding: 0; list-style: none; }

    .line { position: relative; display: grid; gap: 16px; padding-left: 26px; }
    .line::before { content: ""; position: absolute; left: 6px; top: 8px; bottom: 8px; width: 2px; border-radius: 2px; background: linear-gradient(var(--lamp), var(--accent)); }
    .line > li { position: relative; }
    .line > li::before { content: ""; position: absolute; left: -26px; top: .42em; width: 14px; height: 14px; border-radius: 50%; background: var(--bg); border: 3px solid var(--lamp); }

    .meets { display: grid; gap: 10px; }
    .meet { display: flex; gap: 14px; align-items: flex-start; background: var(--surface); border: 1px solid var(--line); border-left: 4px solid var(--accent); border-radius: 14px; padding: 14px 16px; }
    .tm { flex: none; font: 500 13px/1 var(--mono); color: var(--accent); background: var(--indigo-soft); border-radius: 8px; padding: 6px 8px; margin-top: 1px; }
    .mb { min-width: 0; display: grid; gap: 6px; }
    .kids { display: grid; gap: 5px; margin-top: 6px; padding-left: 18px; list-style: disc; color: var(--muted); font-size: 15px; }
    .kids .kids { margin-top: 4px; font-size: 14px; list-style: circle; }
    .kids li::marker { color: var(--faint); }

    .chat { display: grid; gap: 8px; }
    .chat > li { background: var(--surface); border: 1px solid var(--line); border-radius: 12px; padding: 12px 14px; }
    .st { display: inline-block; font: 500 11.5px/1 var(--mono); text-transform: uppercase; letter-spacing: .05em; border-radius: 99px; padding: 4px 8px; margin-left: 4px; vertical-align: 2px; }
    .st.done { background: var(--sage); }
    .st.open { background: var(--lamp-soft); color: var(--lamp); }
    .st.unclear { background: var(--rose); }

    .pair { display: grid; grid-template-columns: repeat(auto-fit, minmax(min(100%, 300px), 1fr)); gap: 12px; padding-top: 40px; }
    .panel { padding: 18px 20px; background: var(--indigo-soft); border-radius: 18px; gap: 10px; }
    .panel h2 { font-size: 18px; }
    .plain { display: grid; gap: 8px; padding-left: 20px; list-style: disc; }
    .panel .plain { font-size: 15px; }
    pre { margin: 0; padding: 14px 16px; overflow-x: auto; background: var(--surface); border: 1px solid var(--line); border-radius: 12px; font: 400 13px/1.6 var(--mono); white-space: pre-wrap; }
    pre code { background: none; padding: 0; }

    .empty { margin-top: 40px; padding-top: 18px; border-top: 1px dashed var(--line); color: var(--faint); font-size: 14px; }
    footer { margin-top: 28px; color: var(--faint); font-size: 12.5px; }

    @media (prefers-reduced-motion: no-preference) {
      .sky, .tiles, .sec, .pair { animation: rise .5s cubic-bezier(.2,.7,.2,1) both; }
      .tiles { animation-delay: .06s; }
      @keyframes rise { from { transform: translateY(8px); } to { transform: none; } }
    }
    @media print {
      body { background: #fff; } .sky { color: var(--ink); background: none; padding: 0; } .moon, footer { display: none; }
      .eyebrow { color: var(--muted); } h1 { color: var(--ink); } .sec { break-inside: avoid; }
    }
    """
}
