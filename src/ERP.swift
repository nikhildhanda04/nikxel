import AppKit

/// Reads the company's Odoo ERP through the browser, no API key. Nikxel keeps
/// its own Chrome profile for the ERP — separate from the WhatsApp one — so it
/// has its own login cookie and never touches the user's keychain or their
/// normal browser. The browser runs headless: background reads (employees,
/// roles, tasks) show no window at all. A window appears only to sign in once,
/// and to show a pre-filled task form on Assign.
///
/// Everything is read with Odoo's own web JSON-RPC (`/web/dataset/call_kw`),
/// evaluated inside the logged-in page, so there's no HTML scraping.
enum ERP {
    static let base = "https://erp.forklyft.in"
    static let port = 9223
    static var profileDir: String { NSHomeDirectory() + "/.nikxel/erp-profile" }

    private static let lock = NSLock()
    private static var cdp: CDPClient?

    // MARK: - Browser

    /// Launches the ERP browser if it isn't up, and minimizes it when
    /// `background`. A REAL (non-headless) window: this server sits behind
    /// Cloudflare, which 403s headless browsers and bare HTTP clients alike,
    /// so only a genuine browser clears it. We never quit+relaunch once signed
    /// in — a relaunch makes Odoo reject the restored session — so the window
    /// is hidden by minimizing, not by killing. Loads the app URL (dashboard
    /// when logged in, login page otherwise). Shares ChromeBot's discovery.
    @discardableResult
    static func launch(background: Bool) -> Bool {
        if isPortOpen() { if background { minimizeWindow() }; return true }
        guard let browser = ChromeBot.availableBrowser() else {
            cblog("ERP: no Chromium browser installed"); return false
        }
        try? FileManager.default.createDirectory(atPath: profileDir, withIntermediateDirectories: true)
        let task = Process()
        task.launchPath = browser.path
        task.arguments = [
            "--remote-debugging-port=\(port)",
            "--user-data-dir=\(profileDir)",
            "--no-first-run", "--no-default-browser-check",
            "--disable-background-networking", "--disable-component-update",
            "--disable-sync", "--disable-default-apps", "--no-pings", "--remote-allow-origins=*",
            "--disable-features=Translate,MediaRouter,OptimizationHints,OptimizationGuideModelDownloading,SpareRendererForSitePerProcess",
            "--app=\(base)/odoo/",
        ]
        task.standardOutput = FileHandle(forWritingAtPath: "/dev/null")
        task.standardError = FileHandle(forWritingAtPath: "/dev/null")
        do { try task.run() } catch { cblog("ERP: launch failed — \(error)"); return false }
        cblog("ERP: launched \(browser.name)")
        guard waitForPort(30) else { return false }
        if background { Thread.sleep(forTimeInterval: 1.0); minimizeWindow() }
        return true
    }

    /// Hide the browser window without killing the process. Minimizes via CDP,
    /// so the signed-in session stays live in that same process.
    static func minimizeWindow() {
        guard let c = client() else { return }
        guard let w = c.sendSync("Browser.getWindowForTarget") as? [String: Any],
              let id = w["windowId"] as? Int else { return }
        c.sendSync("Browser.setWindowBounds", params: ["windowId": id, "bounds": ["windowState": "minimized"]])
    }

    static func quit() {
        lock.lock(); cdp?.disconnect(); cdp = nil; lock.unlock()
        let kill = Process()
        kill.launchPath = "/usr/bin/pkill"
        kill.arguments = ["-f", "user-data-dir=\(profileDir)"]  // SIGTERM: Chrome exits cleanly and flushes cookies
        try? kill.run(); kill.waitUntilExit()
        // Wait for it to actually be gone before anyone relaunches on the same
        // profile — otherwise the fresh session cookie isn't flushed yet and the
        // relaunched browser reads a stale/expired session.
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline && isPortOpen() { Thread.sleep(forTimeInterval: 0.2) }
    }

    private static func client() -> CDPClient? {
        lock.lock(); defer { lock.unlock() }
        if let c = cdp, c.isConnected { return c }
        guard isPortOpen() else { return nil }
        let c = CDPClient(); c.port = port
        // Any erp tab; the headless launch opened one on the ERP origin.
        guard c.connect(urlContains: "erp.forklyft.in") else {
            // No tab yet (freshly launched): make one and retry.
            _ = newTab("\(base)/web/session/get_session_info")
            Thread.sleep(forTimeInterval: 0.6)
            guard c.connect(urlContains: "erp.forklyft.in") else { return nil }
            cdp = c; return c
        }
        cdp = c; return c
    }

    @discardableResult
    private static func newTab(_ url: String) -> Bool {
        guard let u = URL(string: "http://localhost:\(port)/json/new?\(url)") else { return false }
        var req = URLRequest(url: u, timeoutInterval: 3); req.httpMethod = "PUT"
        let sema = DispatchSemaphore(value: 0); var ok = false
        URLSession.shared.dataTask(with: req) { d, _, _ in ok = (d != nil); sema.signal() }.resume()
        _ = sema.wait(timeout: .now() + 3.5)
        return ok
    }

    // MARK: - Session

    /// The signed-in user's Odoo uid, or nil when logged out or unreachable.
    static func sessionUID() -> Int? {
        guard let c = client() else { return nil }
        let js = """
        fetch("\(base)/web/session/get_session_info",{method:"POST",headers:{"Content-Type":"application/json"},\
        body:JSON.stringify({jsonrpc:"2.0",method:"call",params:{}})}).then(r=>r.json())\
        .then(j=>JSON.stringify({uid:(j.result&&j.result.uid)||null,name:(j.result&&j.result.name)||null}))\
        .catch(e=>JSON.stringify({uid:null}))
        """
        guard let out = c.eval(js), let data = out.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj["uid"] as? Int
    }

    static var isConnected: Bool { NikxelSettings.erpConnected }

    // MARK: - Reads

    /// `model.method(args, kwargs)` through Odoo web JSON-RPC, as the logged-in
    /// page. Returns the decoded `result`, or nil on error (logged, not thrown).
    static func callKw(_ model: String, _ method: String, args: [Any], kwargs: [String: Any] = [:]) -> Any? {
        guard let c = client() else { cblog("ERP: \(model).\(method) — no browser session"); return nil }
        let body: [String: Any] = ["jsonrpc": "2.0", "method": "call",
            "params": ["model": model, "method": method, "args": args, "kwargs": kwargs]]
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body),
              let bodyStr = String(data: bodyData, encoding: .utf8) else { return nil }
        // The body is embedded as a JS string literal via JSON.stringify of itself.
        let lit = jsLiteral(bodyStr)
        let js = """
        fetch("\(base)/web/dataset/call_kw",{method:"POST",headers:{"Content-Type":"application/json"},body:\(lit)})\
        .then(r=>r.json()).then(j=>JSON.stringify(j.error?{__erp_error:j.error.data&&j.error.data.message||j.error.message}:(j.result??null)))\
        .catch(e=>JSON.stringify({__erp_error:String(e)}))
        """
        // Writes (create/write/unlink) can be slow when Odoo fires assignment
        // notifications, so give them headroom rather than timing out and
        // leaving an orphan record behind.
        let slow = ["create", "write", "unlink"].contains(method)
        guard let out = c.eval(js, timeout: slow ? 30 : 10) else {
            cblog("ERP: \(model).\(method) — no response (timed out)"); return nil
        }
        guard let data = out.data(using: .utf8),
              // create returns a bare id (e.g. 123) — a JSON fragment, so allow it.
              let decoded = try? JSONSerialization.jsonObject(with: data, options: [.allowFragments]) else {
            cblog("ERP: \(model).\(method) — unreadable response"); return nil
        }
        if let obj = decoded as? [String: Any], let err = obj["__erp_error"] {
            cblog("ERP: \(model).\(method) failed — \(err)"); return nil
        }
        return decoded
    }

    struct Employee { let name: String; let email: String; let role: String; let department: String }

    /// Everyone in hr.employee, for meeting context and the assignee picker.
    static func employees() -> [Employee] {
        let fields = ["name", "work_email", "job_title", "department_id"]
        guard let rows = callKw("hr.employee", "search_read",
                                args: [[], fields],
                                kwargs: ["context": ["active_test": false]]) as? [[String: Any]] else { return [] }
        return rows.map { r in
            // department_id comes back as [id, "Name"] or false.
            let dept = (r["department_id"] as? [Any])?.last as? String ?? ""
            return Employee(
                name: (r["name"] as? String) ?? "",
                email: (r["work_email"] as? String) ?? "",
                role: (r["job_title"] as? String) ?? "",
                department: dept)
        }.filter { !$0.name.isEmpty }
    }

    struct User { let id: Int; let name: String; let email: String }

    /// Internal users a task can be assigned to (res.users, share=false).
    /// Not every employee has a login, so this is the real assignee list.
    static func assignableUsers() -> [User] {
        guard let rows = callKw("res.users", "search_read",
                                args: [[["share", "=", false]], ["name", "login"]]) as? [[String: Any]] else { return [] }
        return rows.compactMap { r in
            guard let id = r["id"] as? Int, let name = r["name"] as? String else { return nil }
            return User(id: id, name: name, email: (r["login"] as? String) ?? "")
        }
    }

    struct Project { let id: Int; let name: String }

    /// Open projects a task can be filed under.
    static func projects() -> [Project] {
        guard let rows = callKw("project.project", "search_read",
                                args: [[], ["id", "name"]]) as? [[String: Any]] else { return [] }
        return rows.compactMap { r in
            guard let id = r["id"] as? Int, let name = r["name"] as? String else { return nil }
            return Project(id: id, name: name)
        }
    }

    // MARK: - Tasks

    /// Create a project.task and return its id (nil on failure). The page's
    /// Assign button then opens `taskURL(id)` in the user's own browser, where
    /// the summary is, so they review and keep editing the real record.
    static func createTask(title: String, descriptionHTML: String,
                           assigneeUserID: Int?, projectID: Int?, deadline: String?) -> Int? {
        var vals: [String: Any] = ["name": title, "description": descriptionHTML]
        if let u = assigneeUserID { vals["user_ids"] = [[6, 0, [u]]] }   // many2many replace
        if let p = projectID { vals["project_id"] = p }
        if let d = deadline, !d.isEmpty { vals["date_deadline"] = d }    // "YYYY-MM-DD HH:MM:SS"
        guard let id = callKw("project.task", "create", args: [vals]) as? Int else { return nil }
        return id
    }

    /// A short task title from a long action-item sentence: the first clause,
    /// capped near 70 chars at a word boundary. The full text goes in the body.
    static func shortTitle(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        var head = t.split(whereSeparator: { ".;:".contains($0) }).first.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? t
        if head.count > 70 {
            let cut = String(head.prefix(70))
            head = (cut.range(of: " ", options: .backwards).map { String(cut[..<$0.lowerBound]) } ?? cut) + "…"
        }
        return head.isEmpty ? String(t.prefix(70)) : head
    }

    /// Task body: the full action-item text, then the meeting context line.
    static func taskDescription(item: String, context: String) -> String {
        var html = "<p>\(htmlEscape(item))</p>"
        if !context.isEmpty { html += "<p>\(htmlEscape(context))</p>" }
        return html
    }

    /// If the meeting's markdown has an "## Agent Prompts" brief whose task
    /// matches this action item, return it as HTML — a full, team-style brief
    /// (goal, background, specifics, done-when) the LLM already wrote at summary
    /// time. nil when there's no close match (non-code tasks have no prompt).
    static func briefFromAgentPrompts(item: String, mdURL: URL) -> String? {
        guard let md = try? String(contentsOf: mdURL, encoding: .utf8),
              let apr = md.range(of: "## Agent Prompts") else { return nil }
        var section = String(md[apr.upperBound...])
        if let next = section.range(of: "\n## ") { section = String(section[..<next.lowerBound]) }
        var prompts: [(head: String, body: String)] = []
        for part in section.components(separatedBy: "### ").dropFirst() {
            guard let nl = part.firstIndex(of: "\n") else { continue }
            let head = String(part[..<nl])
            let after = part[part.index(after: nl)...]
            guard let open = after.range(of: "```") else { continue }
            let rest = after[open.upperBound...]
            guard let close = rest.range(of: "```") else { continue }
            let body = String(rest[..<close.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !body.isEmpty { prompts.append((head, body)) }
        }
        let want = significantWords(item)
        guard !prompts.isEmpty, !want.isEmpty else { return nil }
        var best: (score: Double, body: String)?
        for p in prompts {
            let hay = significantWords(p.head + " " + p.body.prefix(220))
            let score = Double(want.filter(hay.contains).count) / Double(want.count)
            if best == nil || score > best!.score { best = (score, p.body) }
        }
        guard let b = best, b.score >= 0.35 else { return nil }
        return b.body.components(separatedBy: "\n\n")
            .map { "<p>\(htmlEscape($0).replacingOccurrences(of: "\n", with: "<br>"))</p>" }.joined()
    }

    private static func significantWords(_ s: String) -> Set<String> {
        Set(s.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init).filter { $0.count >= 4 })
    }

    private static func htmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    /// Web URL for a task's form — opens the record in whatever browser the
    /// user clicks from. `/web#` is honoured across Odoo 17/18.
    static func taskURL(id: Int) -> String { "\(base)/web#id=\(id)&model=project.task&view_type=form" }

    /// Best-effort match of an action-item assignee name to an internal user.
    /// Exact/first-name match on name, else the local part of the login.
    static func matchUser(_ name: String, in users: [User]) -> User? {
        let n = name.lowercased().trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return nil }
        if let u = users.first(where: { $0.name.lowercased() == n }) { return u }
        let first = n.split(separator: " ").first.map(String.init) ?? n
        if let u = users.first(where: { $0.name.lowercased().split(separator: " ").first.map(String.init) == first }) { return u }
        let hits = users.filter { $0.email.lowercased().split(separator: "@").first.map(String.init)?.contains(first) == true }
        return hits.count == 1 ? hits[0] : nil
    }

    // MARK: - Helpers

    private static func jsLiteral(_ s: String) -> String {
        (try? String(data: JSONSerialization.data(withJSONObject: [s]), encoding: .utf8))
            .map { String($0.dropFirst().dropLast()) } ?? "\"\""
    }

    static func isPortOpen() -> Bool {
        guard let url = URL(string: "http://localhost:\(port)/json/version") else { return false }
        let req = URLRequest(url: url, timeoutInterval: 0.5)
        let sema = DispatchSemaphore(value: 0); var ok = false
        URLSession.shared.dataTask(with: req) { d, _, _ in ok = (d.map { !$0.isEmpty } ?? false); sema.signal() }.resume()
        _ = sema.wait(timeout: .now() + 0.8)
        return ok
    }

    private static func waitForPort(_ seconds: Int) -> Bool {
        let deadline = Date().addingTimeInterval(Double(seconds))
        while Date() < deadline { if isPortOpen() { return true }; Thread.sleep(forTimeInterval: 0.4) }
        return false
    }
}

// MARK: - Sign-in (the one window the user sees)

extension ERP {
    /// Opens a visible ERP window for the one-time Google sign-in, waits until
    /// Odoo reports a logged-in uid, then drops back to headless. `done(true)`
    /// once connected. Call off the main thread.
    static func signIn(done: @escaping (Bool) -> Void) {
        quit()  // clear any prior instance (blocks until gone)
        guard launch(background: false) else { done(false); return }
        // Poll for a login for up to 3 minutes while the user signs in.
        // Give the window a moment to come up, then poll. Closing the window
        // (port drops) means "cancel" -- never reopen it behind the user.
        Thread.sleep(forTimeInterval: 2)
        let deadline = Date().addingTimeInterval(180)
        while Date() < deadline {
            guard isPortOpen() else { cblog("ERP: sign-in window closed — cancelled"); done(false); return }
            if let uid = sessionUID(), uid > 0 {
                cblog("ERP: signed in (uid \(uid))")
                NikxelSettings.erpConnected = true
                minimizeWindow()   // keep THIS process (its session is live); just hide it
                done(true); return
            }
            Thread.sleep(forTimeInterval: 2)
        }
        cblog("ERP: sign-in timed out")
        quit()
        done(false)
    }

    /// On launch: bring the browser up (minimized) if we were connected before.
    static func startIfConnected() {
        guard NikxelSettings.erpConnected else { return }
        DispatchQueue.global(qos: .utility).async { launch(background: true) }
    }
}
