import AppKit

/// Reads the signed-in user's ERP by opening an on-demand headless browser on
/// the SAME isolated profile the ERP sign-in left authenticated (so no cookie
/// capture or injection — the profile already holds the session), walking a
/// bounded set of the ERP's own sections, and grabbing each page's rendered
/// text. Read-only: it navigates and reads innerText; it never submits a form
/// or clicks an action. The browser is quit before `capture()` returns — nothing
/// stays resident. The captured text is handed to the LLM reader in ErpContext.
/// Mirrors erpCrawl.ts. Odoo was proven in the Phase 0 spike; a generic
/// fallback reads whatever a non-Odoo ERP renders.
enum ErpCrawl {
    private static let port = 9224
    private static let maxSections = 8
    private static let keepMin = 400   // below this a page is an empty state / error, not content
    // Friendly Odoo app slugs worth reading, value-first (apps the install lacks
    // return an empty state and get filtered). Employees is an install-specific
    // action id and its people already come from ERP.employees(), so it's omitted.
    private static let odooApps = ["project", "contacts", "to-do", "crm", "sale", "purchase", "stock", "timesheets"]
    private static var host: String { URL(string: ERP.base)?.host ?? "" }

    /// Bounded sweep of the user's ERP → the captured section texts. [] on any
    /// failure (no browser, not authenticated, blocked, logged out).
    static func capture() -> [String] {
        guard ChromeBot.availableBrowser() != nil else { cblog("ErpCrawl: no browser"); return [] }
        guard launch() else { cblog("ErpCrawl: launch failed (profile busy?)"); return [] }
        defer { quit() }
        let cdp = CDPClient(); cdp.port = port
        guard connect(cdp) else { cblog("ErpCrawl: no ERP tab"); return [] }
        guard waitForApp(cdp) else { cblog("ErpCrawl: app didn't load (blocked or logged out)"); return [] }
        let sections = isOdoo(cdp) ? captureOdoo(cdp) : captureGeneric(cdp)
        cblog("ErpCrawl: captured \(sections.count) section(s)")
        return sections
    }

    /// Crawl the connected ERP and fold the result into the sealed ERP facts.
    /// Skips (keeping old facts) unless there's a live session. Call off-main.
    static func ingest(runPrompt: (_ prompt: String, _ kind: String) throws -> String) {
        guard ERP.isConnected, ERP.hasLiveSession() else { cblog("ErpCrawl: ingest skipped — no live ERP session"); return }
        ErpContext.ingestWith(capture: capture, runPrompt: runPrompt)
    }

    // MARK: - Browser lifecycle (headless, isolated profile, own port)

    private static func launch() -> Bool {
        guard let browser = ChromeBot.availableBrowser() else { return false }
        let task = Process()
        task.launchPath = browser.path
        task.arguments = [
            "--headless=new",
            "--remote-debugging-port=\(port)",
            "--user-data-dir=\(ERP.profileDir)",
            "--no-first-run", "--no-default-browser-check",
            "--disable-background-networking", "--disable-component-update",
            "--disable-sync", "--disable-default-apps", "--no-pings", "--remote-allow-origins=*",
            "--window-size=1400,1000",
            "\(ERP.base)/odoo/",
        ]
        task.standardOutput = FileHandle(forWritingAtPath: "/dev/null")
        task.standardError = FileHandle(forWritingAtPath: "/dev/null")
        do { try task.run() } catch { cblog("ErpCrawl: launch error — \(error)"); return false }
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline { if portOpen() { return true }; Thread.sleep(forTimeInterval: 0.4) }
        return false
    }

    private static func quit() {
        let kill = Process()
        kill.launchPath = "/usr/bin/pkill"
        kill.arguments = ["-f", "remote-debugging-port=\(port)"]
        try? kill.run(); kill.waitUntilExit()
    }

    private static func portOpen() -> Bool {
        guard let url = URL(string: "http://localhost:\(port)/json/version") else { return false }
        let req = URLRequest(url: url, timeoutInterval: 0.5)
        let sema = DispatchSemaphore(value: 0); var ok = false
        URLSession.shared.dataTask(with: req) { d, _, _ in ok = (d.map { !$0.isEmpty } ?? false); sema.signal() }.resume()
        _ = sema.wait(timeout: .now() + 0.8)
        return ok
    }

    private static func connect(_ cdp: CDPClient) -> Bool {
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            if cdp.connect(urlContains: host) { return true }
            Thread.sleep(forTimeInterval: 0.4)
        }
        return false
    }

    // MARK: - Navigation helpers

    private static func navigate(_ cdp: CDPClient, _ url: String) {
        cdp.sendSync("Page.navigate", params: ["url": url], timeout: 10)
    }

    private static func textOf(_ cdp: CDPClient, _ selector: String) -> String {
        let js = "(document.querySelector(\(jsString(selector))) || document.body)?.innerText || ''"
        return (cdp.eval(js) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Poll until the content region has real text (stabilized), or timeout.
    private static func waitForContent(_ cdp: CDPClient, selector: String, timeout: Double = 9) {
        let deadline = Date().addingTimeInterval(timeout)
        var last = -1
        while Date() < deadline {
            let len = textOf(cdp, selector).count
            if len > 80 && len == last { return }   // non-trivial and stable
            last = len
            Thread.sleep(forTimeInterval: 1.0)
        }
    }

    /// The authenticated app shell is up (not a login page or a Cloudflare wall).
    private static func waitForApp(_ cdp: CDPClient) -> Bool {
        let deadline = Date().addingTimeInterval(25)
        while Date() < deadline {
            let url = cdp.eval("location.href") ?? ""
            if url.contains("/web/login") || url.lowercased().contains("accounts.google") { return false }
            let ready = cdp.eval("(!!document.querySelector('.o_action_manager, .o_content, .o_main_navbar')).toString()") == "true"
            if ready { return true }
            Thread.sleep(forTimeInterval: 1.0)
        }
        return false
    }

    private static func isOdoo(_ cdp: CDPClient) -> Bool {
        cdp.eval("(!!document.querySelector('.o_main_navbar, .o_web_client')).toString()") == "true"
    }

    // MARK: - Odoo driver (proven in the Phase 0 spike)

    /// Open each friendly Odoo app by its path and grab its content region.
    /// Odoo is a hash/path SPA whose apps aren't plain links, so discovery by
    /// anchor fails; direct `/odoo/<app>` navigation is what works (verified
    /// live). Apps the install lacks render an empty state and fall below
    /// `keepMin`, so the fixed list self-filters to what this user actually has.
    private static func captureOdoo(_ cdp: CDPClient) -> [String] {
        var sections: [String] = []
        for slug in odooApps {
            if sections.count >= maxSections { break }
            navigate(cdp, "\(ERP.base)/odoo/\(slug)")
            waitForContent(cdp, selector: ".o_content")
            let text = textOf(cdp, ".o_content")
            if text.count > keepMin { sections.append("## \(slug)\n\(text)") }
        }
        return sections
    }

    // MARK: - Generic fallback (any non-Odoo web ERP)

    /// Best-effort: follow the visible same-origin nav links and grab each
    /// page's body text. Captures *something* for an ERP we have no driver for.
    private static func captureGeneric(_ cdp: CDPClient) -> [String] {
        let json = cdp.eval("""
        JSON.stringify([...document.querySelectorAll('nav a, aside a, [role=navigation] a, .menu a')]
          .map(a => ({label: (a.textContent||'').trim(), href: a.href||''}))
          .filter(x => x.href && x.href.startsWith(location.origin)))
        """) ?? "[]"
        var links: [(label: String, href: String)] = []
        if let data = json.data(using: .utf8),
           let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: String]] {
            var seen = Set<String>()
            for item in arr {
                guard let href = item["href"], !seen.contains(href) else { continue }
                seen.insert(href); links.append((label: item["label"] ?? "", href: href))
            }
        }
        var sections: [String] = ["## Home\n" + textOf(cdp, "body")]
        for link in links {
            if sections.count >= maxSections { break }
            navigate(cdp, link.href)
            waitForContent(cdp, selector: "main")
            let text = textOf(cdp, "main")
            if text.count > keepMin { sections.append("## \(link.label)\n\(text)") }
        }
        return sections
    }

    private static func jsString(_ s: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [s])) ?? Data("[\"\"]".utf8)
        let arr = String(data: data, encoding: .utf8) ?? "[\"\"]"
        return String(arr.dropFirst().dropLast())   // "[\"x\"]" -> "\"x\""
    }
}
