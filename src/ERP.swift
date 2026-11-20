import AppKit

/// Talks to the company's Odoo ERP over its web JSON-RPC — no API key and no
/// resident browser. A real browser window opens exactly once, for the Google
/// sign-in (this server's Cloudflare clears a genuine browser but 403s headless
/// ones); from it we read the Odoo `session_id` cookie, store it, and close the
/// browser. Every read and write after that is a plain HTTPS call carrying that
/// cookie — verified to clear Cloudflare — so nothing runs in the background.
/// The session lasts months; only when Odoo finally expires it, or the user
/// disconnects, do they sign in again.
enum ERP {
    static let base = "https://erp.forklyft.in"
    static let port = 9223
    static var profileDir: String { NSHomeDirectory() + "/.nikxel/erp-profile" }

    private static let lock = NSLock()
    private static var cdp: CDPClient?
    private static let sessionFile = NSHomeDirectory() + "/.nikxel/erp_session"
    private static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/159.0.0.0 Safari/537.36"

    // MARK: - Browser

    /// Opens the ERP browser for the one-time Google sign-in. A REAL
    /// (non-headless) window, because this server's Cloudflare clears a genuine
    /// browser but 403s headless ones. Loads the login/app URL and shares
    /// ChromeBot's discovery. After sign-in we read the session cookie and quit;
    /// no browser is kept for the reads and writes, which go over plain HTTPS.
    @discardableResult
    static func launch() -> Bool {
        if isPortOpen() { return true }
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
        return true
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

    /// The Odoo session cookie captured at sign-in, or nil. Lives in a 0600 file
    /// (like the share token), not the Chrome profile, so reads need no browser.
    static var storedSession: String? {
        get {
            let s = (try? String(contentsOfFile: sessionFile, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (s?.isEmpty == false) ? s : nil
        }
        set {
            if let v = newValue, !v.isEmpty {
                try? FileManager.default.createDirectory(atPath: (sessionFile as NSString).deletingLastPathComponent,
                                                         withIntermediateDirectories: true)
                try? v.write(toFile: sessionFile, atomically: true, encoding: .utf8)
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: sessionFile)
            } else {
                try? FileManager.default.removeItem(atPath: sessionFile)
            }
        }
    }

    static var isConnected: Bool { NikxelSettings.erpConnected && storedSession != nil }

    /// Whether the stored session still logs in right now (a cheap HTTP check).
    /// Lets Assign tell a real sign-out apart from a transient hiccup and ask the
    /// user to reconnect instead of failing opaquely.
    static func hasLiveSession() -> Bool {
        guard storedSession != nil else { return false }
        return (sessionUID() ?? 0) > 0
    }

    /// The signed-in user's Odoo uid, or nil when logged out or unreachable.
    static func sessionUID() -> Int? {
        guard let resp = post("/web/session/get_session_info", params: [:], timeout: 10),
              let result = resp["result"] as? [String: Any] else { return nil }
        return result["uid"] as? Int
    }

    /// Clears the session on a confirmed sign-out, so the menu and the Assign
    /// buttons reflect that the user must reconnect. Only on a real Odoo
    /// SessionExpired — never on a transient network failure.
    private static func markDisconnected() {
        storedSession = nil
        NikxelSettings.erpConnected = false
        cblog("ERP: session expired — reconnect needed")
    }

    /// One Odoo web-JSON-RPC POST carrying the stored session cookie; the decoded
    /// JSON object, or nil on a transport failure. A browser-like User-Agent plus
    /// the `session_id` cookie are all this server's Cloudflare needs (verified).
    private static func post(_ path: String, params: [String: Any], timeout: Double) -> [String: Any]? {
        guard let sid = storedSession, let url = URL(string: base + path),
              let data = try? JSONSerialization.data(withJSONObject:
                ["jsonrpc": "2.0", "method": "call", "params": params]) else { return nil }
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("session_id=\(sid)", forHTTPHeaderField: "Cookie")
        req.httpBody = data
        let sema = DispatchSemaphore(value: 0); var out: [String: Any]?
        URLSession.shared.dataTask(with: req) { d, _, _ in
            defer { sema.signal() }
            if let d = d { out = try? JSONSerialization.jsonObject(with: d) as? [String: Any] }
        }.resume()
        _ = sema.wait(timeout: .now() + timeout + 2)
        return out
    }

    // MARK: - Reads

    /// `model.method(args, kwargs)` through Odoo web JSON-RPC, carrying the
    /// stored session cookie — no browser. Returns the decoded `result` (a bare
    /// id for create, a list for search_read, …), or nil on error (logged, not
    /// thrown). A SessionExpired clears the session so the UI can prompt a
    /// reconnect.
    static func callKw(_ model: String, _ method: String, args: [Any], kwargs: [String: Any] = [:]) -> Any? {
        guard storedSession != nil else { cblog("ERP: \(model).\(method) — not connected"); return nil }
        // Writes (create/write/unlink) can be slow when Odoo fires assignment
        // notifications, so give them headroom.
        let slow = ["create", "write", "unlink"].contains(method)
        guard let resp = post("/web/dataset/call_kw",
                              params: ["model": model, "method": method, "args": args, "kwargs": kwargs],
                              timeout: slow ? 30 : 15) else {
            cblog("ERP: \(model).\(method) — no response"); return nil
        }
        if let err = resp["error"] as? [String: Any] {
            let name = (err["data"] as? [String: Any])?["name"] as? String ?? ""
            if (err["code"] as? Int) == 100 || name.contains("SessionExpired") { markDisconnected() }
            cblog("ERP: \(model).\(method) failed — \(err["message"] ?? err)"); return nil
        }
        return resp["result"]
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

    struct TouchedTask { let name, project, stage, deadline: String }

    /// The user's tasks written on `day` (local), for the 10pm summary. [] when not connected or on any failure.
    static func tasksTouched(on day: Date) -> [TouchedTask] {
        guard isConnected, let uid = sessionUID(), uid > 0 else { return [] }
        let start = Calendar.current.startOfDay(for: day)
        guard let end = Calendar.current.date(byAdding: .day, value: 1, to: start) else { return [] }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "UTC"); f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        guard let rows = callKw("project.task", "search_read",
                                args: [[["user_ids", "in", [uid]], ["write_date", ">=", f.string(from: start)], ["write_date", "<", f.string(from: end)]],
                                       ["name", "project_id", "stage_id", "date_deadline"]]) as? [[String: Any]] else { return [] }
        // Many2one fields come back as [id, "Name"] or false.
        func m2o(_ v: Any?) -> String { (v as? [Any])?.last as? String ?? "" }
        return rows.compactMap { r in
            guard let name = r["name"] as? String, !name.isEmpty else { return nil }
            return TouchedTask(name: name, project: m2o(r["project_id"]), stage: m2o(r["stage_id"]), deadline: r["date_deadline"] as? String ?? "")
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

    /// Task body for a plain (non-code) item: the action split into points under
    /// a bold heading, then the meeting context — rendered as the structured HTML
    /// the ERP shows, instead of two flat paragraphs.
    static func taskDescription(item: String, context: String) -> String {
        var md = "**What to do**\n\n" + bulletize(item)
        if !context.isEmpty { md += "\n**Context**\n\n\(context)\n" }
        return NoteExporter.richHTML(from: TwinProfile.correct(md))
    }

    /// A run-on action item as bullet lines, split on clause breaks ("; ") and
    /// newlines so the body reads as points. A single clause stays one bullet.
    private static func bulletize(_ s: String) -> String {
        let parts = s.components(separatedBy: .newlines)
            .flatMap { $0.components(separatedBy: "; ") }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return (parts.isEmpty ? [s] : parts).map { "- \($0)" }.joined(separator: "\n") + "\n"
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
        return NoteExporter.richHTML(from: b.body)
    }

    private static func significantWords(_ s: String) -> Set<String> {
        Set(s.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init).filter { $0.count >= 4 })
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
    /// Opens a visible ERP window for the one-time Google sign-in. Polls until
    /// the browser holds a logged-in Odoo session, grabs its `session_id` cookie,
    /// stores it, and closes the browser — from then on every call is plain
    /// HTTPS, nothing stays open. `done(true)` once connected. Call off the main
    /// thread.
    static func signIn(done: @escaping (Bool) -> Void) {
        quit()  // clear any prior instance (blocks until gone)
        guard launch() else { done(false); return }
        // Poll for a login for up to 3 minutes while the user signs in.
        // Give the window a moment to come up, then poll. Closing the window
        // (port drops) means "cancel" -- never reopen it behind the user.
        Thread.sleep(forTimeInterval: 2)
        let deadline = Date().addingTimeInterval(180)
        while Date() < deadline {
            guard isPortOpen() else {
                cblog("ERP: sign-in window closed — cancelled"); storedSession = nil; done(false); return
            }
            // captureSession stores whatever cookie the browser currently holds
            // (anonymous at first); sessionUID over HTTP confirms it's logged in.
            if captureSession(), let uid = sessionUID(), uid > 0 {
                cblog("ERP: signed in (uid \(uid))")
                NikxelSettings.erpConnected = true
                quit()   // no resident browser — reads and writes go over HTTPS
                done(true); return
            }
            Thread.sleep(forTimeInterval: 2)
        }
        cblog("ERP: sign-in timed out")
        storedSession = nil
        quit()
        done(false)
    }

    /// Read the Odoo `session_id` cookie from the signed-in browser via CDP and
    /// store it. false until the browser actually has one.
    private static func captureSession() -> Bool {
        guard let c = client(),
              let r = c.sendSync("Storage.getCookies") as? [String: Any],
              let cookies = r["cookies"] as? [[String: Any]],
              let sid = cookies.first(where: {
                  ($0["name"] as? String) == "session_id" &&
                  (($0["domain"] as? String) ?? "").contains("forklyft")
              })?["value"] as? String, !sid.isEmpty else { return false }
        storedSession = sid
        return true
    }

    /// Nothing to start — reads and writes are plain HTTPS with the stored
    /// cookie; no browser runs in the background. Kept for the launch call site.
    static func startIfConnected() {}
}
