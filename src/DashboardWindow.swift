import AppKit
import EventKit
import WebKit

/// The Nikxel dashboard: every option the menu bar holds, in one window
/// (DashboardPage.swift), in the onboarding's look. Each control goes through
/// the same NikxelAppDelegate handler its menu item does, so the menu, the
/// running bot and this window never disagree; the few settings with no menu
/// item are written to NikxelSettings directly. The page only draws `state()`
/// and posts back what was changed.
final class DashboardWindowController: NSWindowController, NSWindowDelegate, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
    private static var shared: DashboardWindowController?

    static func show() {
        if shared == nil { shared = DashboardWindowController() }
        shared?.present()
    }

    /// Shows the window on `section` (an automation's card opens Automations).
    static func show(section: String) {
        if shared == nil { shared = DashboardWindowController() }
        shared?.section = section
        shared?.showSection()
        shared?.present()
        shared?.web.evaluateJavaScript("nx.go(\(PageAssets.json([section]) ?? "[]")[0])")
    }

    /// A summary page the reader can show: an .html or .pdf under ~/Documents/nikxel.
    static func canRead(_ url: URL) -> Bool {
        ["html", "pdf"].contains(url.pathExtension.lowercased())
            && url.resolvingSymlinksInPath().path.hasPrefix(SummaryLibrary.root.resolvingSymlinksInPath().path + "/")
    }

    /// Shows the window with `url` open in the reader.
    static func open(summary url: URL) {
        show()
        shared?.read(url)
    }

    private let web: WKWebView
    private let strip: DragStrip
    /// The summary open in the reader, over the main area; nil on the settings.
    /// Summaries open in tabs, like files in an editor; `active` is the one shown,
    /// nil while a section is. Each tab keeps its own page (scroll, edits, chat).
    private final class Tab { var file: URL; let view = SummaryViewer(); init(_ file: URL) { self.file = file } }
    private var tabs: [Tab] = []
    private var active: Tab?
    /// The sidebar's width: the page's 248px column, or 76 folded to icons.
    private var sideWidth: CGFloat { sideCollapsed ? 76 : 248 }
    private var sideCollapsed = UserDefaults.standard.bool(forKey: "nikxel.dashboardSideCollapsed")
    /// The text file open in the page's editor (personality, a contact list, a template).
    private var editing: (url: URL, title: String, help: String)?
    /// The Chat section's conversation, the same engine as the avatar's chat.
    private var chat: ChatSession?
    /// Today's calendar, fetched at most every few minutes as the window comes forward.
    private var events: [[String: Any]] = []
    private var eventsFetched: Date?
    /// The tab bar the page draws above the open summary.
    /// (the page's 248px column).
    private static let barHeight: CGFloat = 52
    private var pageLoaded = false
    private var section = "home"
    private var app: NikxelAppDelegate? { NSApp.delegate as? NikxelAppDelegate }

    /// The page's paper (#f6f4ee, or #151411 in dark), so nothing flashes before it paints.
    private static let paper = NSColor(name: nil) { a in
        a.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0.082, green: 0.078, blue: 0.067, alpha: 1)
            : NSColor(srgbRed: 0.965, green: 0.957, blue: 0.933, alpha: 1)
    }

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1120, height: 780),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.title = "Nikxel"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.appearance = Self.appearance()
        window.backgroundColor = Self.paper
        window.minSize = NSSize(width: 900, height: 620)
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("NikxelDashboard")

        let config = WKWebViewConfiguration()
        PageAssets.install(into: config.userContentController)
        web = WKWebView(frame: .zero, configuration: config)
        strip = DragStrip(frame: NSRect(x: 0, y: 740, width: 1120, height: 40))
        super.init(window: window)
        window.delegate = self
        Automations.shared.onChange = { [weak self] in self?.push() }
        config.userContentController.add(self, name: "nx")
        web.navigationDelegate = self
        web.uiDelegate = self
        web.setValue(false, forKey: "drawsBackground")

        let content = NSView(frame: NSRect(x: 0, y: 0, width: 1120, height: 780))
        web.frame = content.bounds
        web.autoresizingMask = [.width, .height]
        content.addSubview(web)
        strip.autoresizingMask = [.width, .minYMargin]
        content.addSubview(strip)
        window.contentView = content
        window.center()
        web.loadHTMLString(DashboardPage.html, baseURL: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("DashboardWindowController does not support NSCoding")
    }

    private func present() {
        // Reopened: start the page over so it fades in again, on the same section.
        if pageLoaded, window?.isVisible == false {
            tabs.forEach { $0.view.removeFromSuperview() }
            tabs = []
            showSection()
            chat = nil
            pageLoaded = false
            web.loadHTMLString(DashboardPage.html, baseURL: nil)
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Back from the browser (Google, Slack), a text editor or another app:
    /// the connections may have changed.
    func windowDidBecomeKey(_ notification: Notification) { push() }

    // MARK: - Page bridge

    /// The page's confirm() ("Delete this automation?") as a sheet.
    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        guard let window else { return completionHandler(alert.runModal() == .alertFirstButtonReturn) }
        alert.beginSheetModal(for: window) { completionHandler($0 == .alertFirstButtonReturn) }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        pageLoaded = true
        if let json = PageAssets.json(PageAssets.spriteRows()) { web.evaluateJavaScript("nx.frames(\(json))") }
        push()
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        switch type {
        case "section":
            section = body["id"] as? String ?? "home"
        case "set":
            guard let key = body["key"] as? String else { return }
            set(key, body["value"])
            push()
        case "tourDone":
            NikxelSettings.dashboardTourDone = true
            push()
        case "chatStart":
            startChat()
        case "chat":
            let id = body["id"] as? Int ?? 0
            startChat()
            chat?.send(body["text"] as? String ?? "") { [weak self] in self?.reply(id, $0) }
        case "chatMic":
            let id = body["id"] as? Int ?? 0
            startChat()
            chat?.mic(meeting: app?.meetingCoordinator?.isRecording ?? false) { [weak self] in self?.reply(id, $0) }
        case "chatNew":
            chat?.stopMic()
            chat = nil
            startChat()
        case "task":
            // A meeting's action item, ticked in the Tasks list or a person's page.
            if let path = body["md"] as? String, let n = body["n"] as? Int { tickItem(URL(fileURLWithPath: path), n: n, done: body["done"] as? Bool ?? false) }
            push()
        case "dayTask":
            if let path = body["id"] as? String, let i = body["i"] as? Int { _ = DayPage.tick(URL(fileURLWithPath: path), index: i, done: true) }
            push()
        case "search":
            let q = body["q"] as? String ?? ""
            let files = SummaryLibrary.scan().map { (id: $0.file.path, md: $0.file.deletingPathExtension().appendingPathExtension("md")) }
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let found = DashboardData.search(q, in: files)
                DispatchQueue.main.async {
                    guard let qs = PageAssets.json([q]), let json = PageAssets.json(found) else { return }
                    self?.web.evaluateJavaScript("nx.found(\(qs)[0], \(json))")
                }
            }
        case "neverReply":
            if let name = body["name"] as? String, !name.isEmpty, !WAContactLists.contains(.neverReply, contact: name) {
                let url = WAContactLists.seedIfMissing(.neverReply)
                let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                try? (text + (text.hasSuffix("\n") || text.isEmpty ? "" : "\n") + name + "\n").write(to: url, atomically: true, encoding: .utf8)
            }
            push()
        case "openURL":
            if let u = (body["url"] as? String).flatMap(URL.init(string:)), u.scheme == "https" { NSWorkspace.shared.open(u) }
        case "openChat":
            guard let name = body["name"] as? String else { return }
            app?.openWhatsAppWindow()
            DispatchQueue.global(qos: .userInitiated).async { _ = ChromeWhatsApp.openChatBySearch(name) }
        case "autoSave":
            guard let d = body["a"] as? [String: Any] else { return }
            let a = Automation(id: d["id"] as? String ?? "", name: d["name"] as? String ?? "", trigger: d["trigger"] as? String ?? "",
                               time: d["time"] as? String ?? "09:00", days: d["days"] as? String ?? "daily",
                               instruction: d["instruction"] as? String ?? "")
            guard var clean = Automation.clean(a) else { return }
            var list = Automation.load()
            if let i = list.firstIndex(where: { $0.id == clean.id }) { clean.enabled = list[i].enabled; clean.lastRun = list[i].lastRun; list[i] = clean }
            else { list.append(clean) }
            Automation.save(list)
            push()
        case "autoToggle":
            var list = Automation.load()
            if let i = list.firstIndex(where: { $0.id == body["id"] as? String }) { list[i].enabled = body["on"] as? Bool ?? true; Automation.save(list) }
            push()
        case "autoDelete":
            Automation.save(Automation.load().filter { $0.id != body["id"] as? String })
            push()
        case "autoRun":
            if let a = Automation.load().first(where: { $0.id == body["id"] as? String }) { Automations.shared.runNow(a) }
        case "autoMake":
            let id = body["id"] as? Int ?? 0
            Automations.shared.make(body["text"] as? String ?? "") { [weak self] a in
                self?.reply(id, a.map { $0.dict } ?? ["error": "I couldn't turn that into an automation. Try saying when it should run and what I should do."])
            }
        case "autoSuggest":
            let id = body["id"] as? Int ?? 0
            Automations.shared.suggest { [weak self] list in
                self?.reply(id, list.map { $0.0.dict.merging(["why": $0.why]) { a, _ in a } })
            }
        case "saveFile":
            if let edit = editing, let text = body["text"] as? String {
                try? text.write(to: edit.url, atomically: true, encoding: .utf8)
            }
            editing = nil
            push()
        case "closeFile":
            editing = nil
            push()
        case "tab":
            if let id = body["id"] as? String, let t = tabs.first(where: { $0.file.path == id }) { activate(t) }
        case "closeTab":
            if let id = body["id"] as? String { closeTab(id) }
            push()
        case "side":
            sideCollapsed = body["collapsed"] as? Bool ?? false
            UserDefaults.standard.set(sideCollapsed, forKey: "nikxel.dashboardSideCollapsed")
            layout(animated: true)
        case "open":
            if let id = body["id"] as? String { open(URL(fileURLWithPath: id)) }
        case "action":
            guard let name = body["name"] as? String else { return }
            run(name)
            // Most actions open something or change a connection; give it a
            // moment, then show where things stand.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.push() }
        default:
            break
        }
    }

    // MARK: - Tasks, people, today

    /// The .md beside the page, and the page's box with it.
    private func tickItem(_ md: URL, n: Int, done: Bool) {
        guard let text = try? String(contentsOf: md, encoding: .utf8),
              let updated = DashboardData.markItem(text, n: n, done: done),
              (try? updated.write(to: md, atomically: true, encoding: .utf8)) != nil else { return }
        let page = md.deletingPathExtension().appendingPathExtension("html")
        if let html = try? String(contentsOf: page, encoding: .utf8) {
            let ticked = html.replacingOccurrences(of: "id=\"task-\(n)\"( checked)?", with: "id=\"task-\(n)\"" + (done ? " checked" : ""), options: .regularExpression)
            try? ticked.write(to: page, atomically: true, encoding: .utf8)
        }
    }

    /// Today: the calendar (refetched now and then), the latest day page's open tasks.
    private func today(_ library: [SummaryLibrary.Entry]) -> [String: Any] {
        if GoogleAuth.shared.isAuthorized, eventsFetched.map({ Date().timeIntervalSince($0) > 300 }) ?? true {
            eventsFetched = Date()
            fetchEvents()
        }
        var out: [String: Any] = ["events": events, "google": GoogleAuth.shared.isAuthorized]
        if let day = library.first(where: { $0.kind == "daily" && $0.file.pathExtension == "html" }),
           let md = try? String(contentsOf: day.file.deletingPathExtension().appendingPathExtension("md"), encoding: .utf8) {
            out["dayId"] = day.file.path
            out["dayDate"] = day.date
            out["openTasks"] = DayPage.openTasks(in: md).map { ["i": $0.i, "text": $0.text] }
        }
        return out
    }

    private func fetchEvents() {
        GoogleAuth.shared.withAccessToken { [weak self] token in
            guard let token else { return }
            let iso = ISO8601DateFormatter(), now = Date()
            let end = Calendar.current.date(bySettingHour: 23, minute: 59, second: 59, of: now) ?? now
            var c = URLComponents(string: "https://www.googleapis.com/calendar/v3/calendars/primary/events")!
            c.queryItems = [URLQueryItem(name: "timeMin", value: iso.string(from: now.addingTimeInterval(-1800))),
                            URLQueryItem(name: "timeMax", value: iso.string(from: end)),
                            URLQueryItem(name: "singleEvents", value: "true"), URLQueryItem(name: "orderBy", value: "startTime"),
                            URLQueryItem(name: "maxResults", value: "12")]
            var req = URLRequest(url: c.url!)
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            URLSession.shared.dataTask(with: req) { data, _, _ in
                guard let data, let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                      let items = obj["items"] as? [[String: Any]] else { return }
                let events = items.compactMap { item -> [String: Any]? in
                    guard let s = (item["start"] as? [String: Any])?["dateTime"] as? String,
                          let start = GoogleCalendarWatcher.parseGCalDate(s) else { return nil }   // all-day events aren't meetings
                    let end = ((item["end"] as? [String: Any])?["dateTime"] as? String).flatMap(GoogleCalendarWatcher.parseGCalDate) ?? start
                    return ["title": item["summary"] as? String ?? "Meeting", "start": start.timeIntervalSince1970,
                            "end": end.timeIntervalSince1970, "link": item["hangoutLink"] as? String ?? ""]
                }
                DispatchQueue.main.async { self?.events = events; self?.push() }
            }.resume()
        }
    }

    /// Cost and calls per day for the last 14 days, oldest first.
    private static func usageDays() -> [[String: Any]] {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return (0..<14).reversed().compactMap { back -> [String: Any]? in
            guard let d = Calendar.current.date(byAdding: .day, value: -back, to: Date()) else { return nil }
            let t = UsageLog.totals(for: d).values
            return ["day": f.string(from: d), "cost": t.reduce(0) { $0 + $1.cost }, "calls": t.reduce(0) { $0 + $1.calls }]
        }
    }

    // MARK: - Chat

    private func startChat() {
        guard chat == nil, let agent = app?.meetingCoordinator?.momGen else { return }
        let session = ChatSession(agent: agent)
        chat = session
        // What it can see takes the start-up reads (WhatsApp, mail, the team feed).
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let sources = session.sources()
            DispatchQueue.main.async {
                guard let self, self.chat === session, let json = PageAssets.json(sources) else { return }
                self.web.evaluateJavaScript("nx.sources(\(json))")
            }
        }
    }

    private func reply(_ id: Int, _ value: Any) {
        guard let json = PageAssets.json([value]) else { return }
        web.evaluateJavaScript("nx.reply(\(id), \(json)[0])")
    }

    // MARK: - Reader

    /// A library row: pages and PDFs in the reader, .md and .docx in their own app.
    private func open(_ url: URL) {
        if Self.canRead(url) { read(url) } else { NSWorkspace.shared.open(url) }
    }

    private func read(_ url: URL) {
        if let open = tabs.first(where: { $0.file == url }) { return activate(open) }
        let tab = Tab(url)
        tab.view.autoresizingMask = [.width, .height]
        tab.view.onTitle = { [weak self] _ in self?.push() }
        tab.view.onOpen = { [weak self, weak tab] url in tab?.file = url; self?.push() }   // renamed, or the client view
        tab.view.show(url)
        tabs.append(tab)
        activate(tab)
    }

    private func activate(_ tab: Tab) {
        guard let content = window?.contentView else { return }
        active = tab
        for t in tabs where t !== tab { t.view.removeFromSuperview() }
        if tab.view.superview == nil { content.addSubview(tab.view, positioned: .below, relativeTo: strip) }
        layout()
        push()
    }

    /// Back to the section; the tabs stay open.
    private func showSection() {
        active?.view.removeFromSuperview()
        active = nil
        layout()
    }

    private func closeTab(_ path: String) {
        guard let i = tabs.firstIndex(where: { $0.file.path == path }) else { return }
        let tab = tabs.remove(at: i)
        tab.view.removeFromSuperview()
        if tab === active {
            if tabs.isEmpty { showSection() } else { activate(tabs[min(i, tabs.count - 1)]) }
        }
        layout()
    }

    /// The open summary fills the main column under the tab bar. The tab bar's
    /// buttons sit under the drag strip, so then only the sidebar's top drags.
    private func layout(animated: Bool = false) {
        guard let content = window?.contentView else { return }
        let b = content.bounds
        let frame = NSRect(x: sideWidth, y: 0, width: b.width - sideWidth, height: b.height - Self.barHeight)
        if let v = active?.view {
            if animated {
                NSAnimationContext.runAnimationGroup { c in c.duration = 0.35; c.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1); v.animator().frame = frame }
            } else { v.frame = frame }
        }
        strip.frame = NSRect(x: 0, y: b.height - 40, width: active == nil && tabs.isEmpty ? b.width : sideWidth, height: 40)
        strip.autoresizingMask = active == nil && tabs.isEmpty ? [.width, .minYMargin] : [.minYMargin]
    }

    private func push() {
        guard pageLoaded, let json = PageAssets.json(state()) else { return }
        web.evaluateJavaScript("nx.state(\(json))")
    }

    private func state() -> [String: Any] {
        let reminders = EKEventStore.authorizationStatus(for: .reminder)
        let today = UsageLog.totals(for: Date())
        var all = UsageLog.Totals()
        for t in today.values { all.calls += t.calls; all.tokens += t.tokens; all.cost += t.cost }
        let (avg, days) = UsageLog.dailyAverage()
        let library = SummaryLibrary.scan()
        let (tasks, people) = DashboardData.tasksAndPeople(library, me: [NikxelSettings.userName, NikxelSettings.waOwnName])
        let waLogs = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Nikxel/whatsapp")
        return [
            "section": section,
            "library": library.map(\.dict),
            "tabs": tabs.map { t -> [String: Any] in
                let e = library.first { $0.file == t.file }
                return ["id": t.file.path, "title": e?.title ?? t.view.title.flatMap { $0.isEmpty ? nil : $0 } ?? t.file.deletingPathExtension().lastPathComponent,
                        "date": e?.date ?? "", "kind": e?.kind ?? ""]
            },
            "active": active?.file.path ?? NSNull(),
            "sideCollapsed": sideCollapsed,
            "recording": app?.meetingCoordinator?.isRecording ?? false,
            "micMuted": app?.meetingCoordinator?.recorder.isMicMuted ?? false,
            "visible": app?.window?.isVisible ?? false,
            "templateShipped": SummaryTemplates.isShipped(NikxelSettings.summaryTemplate),
            "openInApp": NikxelSettings.openSummariesInApp,
            "appearance": NikxelSettings.appearance,
            "tour": !NikxelSettings.dashboardTourDone,
            "tasks": tasks,
            "people": people,
            "today": self.today(library),
            "recordingSince": app?.meetingCoordinator?.recorder.startedAt?.timeIntervalSince1970 ?? 0,
            "captureLabel": CaptureMode.current == .notes ? "Notes" : "Meeting",
            "botReplies": DashboardData.botReplies(on: Date(), in: waLogs),
            "neverReply": WAContactLists.names(.neverReply),
            "usageDays": Self.usageDays(),
            "automations": Automation.load().map(\.dict),
            "automationRuns": Automations.shared.runs,
            "automationRunning": Automations.shared.running ?? "",
            "ideas": Automation.ideas.map(\.dict),
            "editor": editing.map { e -> [String: Any] in
                ["title": e.title, "help": e.help, "text": (try? String(contentsOf: e.url, encoding: .utf8)) ?? ""]
            } ?? NSNull(),
            "hour": Calendar.current.component(.hour, from: Date()),
            "name": NikxelSettings.hasUserName ? NikxelSettings.userName : (NikxelSettings.accountFirstName ?? ""),
            "waOwnName": NikxelSettings.waOwnName,
            "userContext": NikxelSettings.userContext,
            "language": NikxelSettings.language,
            "transcriptionLanguage": NikxelSettings.transcriptionLanguage,
            "avatarSize": NikxelSettings.avatarSize,
            "agent": NikxelSettings.connectedAgent.rawValue,
            "agents": CodingAgent.allCases.map { ["id": $0.rawValue, "name": $0.displayName] },
            "captureMode": CaptureMode.current.rawValue,
            "noteFormat": NikxelSettings.noteFormat.rawValue,
            "noteFormats": NoteExporter.Format.allCases.map { ["id": $0.rawValue, "name": $0.displayName] },
            "autoRecordCalls": NikxelSettings.autoRecordCalls,
            "forceMeeting": app?.meetingDetector?.manualOverride ?? false,
            "summaryMinutes": NikxelSettings.summaryMinutes,
            "summaryTemplate": NikxelSettings.summaryTemplate,
            "templates": SummaryTemplates.available().map { ["id": $0.slug, "name": $0.name] },
            "googleSyncEnabled": NikxelSettings.googleSyncEnabled,
            "botEnabled": ChatbotEngine.shared.isEnabled,
            "waBotMode": NikxelSettings.waBotMode.rawValue,
            "waModes": WABotMode.allCases.map { ["id": $0.rawValue, "name": $0.displayName] },
            "waUnattendedMinutes": NikxelSettings.waUnattendedMinutes,
            "waGroupReplies": NikxelSettings.waGroupReplies,
            "waDraftOnly": NikxelSettings.waDraftOnly,
            "waQuietHours": NikxelSettings.waQuietHours,
            "waQuietFrom": NikxelSettings.waQuietFrom,
            "waQuietTo": NikxelSettings.waQuietTo,
            "waWorkContext": NikxelSettings.waWorkContext,
            "waChatTasks": NikxelSettings.waChatTasks,
            "botMemoryDays": NikxelSettings.botMemoryDays,
            "projectsRoot": (NikxelSettings.projectsRoot as NSString).abbreviatingWithTildeInPath,
            "status": [
                "whatsapp": NikxelSettings.whatsappConnected,
                "google": GoogleAuth.shared.isAuthorized,
                "slack": Slack.isConnected,
                "reminders": reminders == .fullAccess,
                "dashboard": CloudSync.token != nil,
                "erp": NikxelSettings.erpConnected,
            ],
            "usageToday": UsageLog.line(all),
            "usageAverage": days == 0 ? "" : UsageLog.line(avg),
        ]
    }

    // MARK: - Changes

    /// A stand-in menu item, for the handlers that read their choice from one.
    private func item(_ value: Any) -> NSMenuItem {
        let item = NSMenuItem()
        item.representedObject = value
        return item
    }

    private func set(_ key: String, _ value: Any?) {
        let on = value as? Bool ?? false
        let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let number = (value as? NSNumber)?.intValue ?? Int(text) ?? 0
        // Toggles go through the menu's own handler, so its side effects
        // (the bot's poller, the menu titles) happen exactly as from the menu.
        func flip(_ current: Bool, _ handler: () -> Void) { if on != current { handler() } }
        switch key {
        case "botEnabled": flip(ChatbotEngine.shared.isEnabled) { app?.toggleBotEnabled() }
        case "waGroupReplies": flip(NikxelSettings.waGroupReplies) { app?.toggleWAGroups() }
        case "waDraftOnly": flip(NikxelSettings.waDraftOnly) { app?.toggleWADraftOnly() }
        case "waQuietHours": flip(NikxelSettings.waQuietHours) { app?.toggleWAQuietHours() }
        case "waWorkContext": flip(NikxelSettings.waWorkContext) { app?.toggleWAWorkContext() }
        case "waChatTasks": flip(NikxelSettings.waChatTasks) { app?.toggleWAChatTasks() }
        case "googleSyncEnabled": flip(NikxelSettings.googleSyncEnabled) { app?.toggleGoogleSync() }
        case "forceMeeting": flip(app?.meetingDetector?.manualOverride ?? false) { app?.toggleForceMeeting() }
        case "autoRecordCalls": NikxelSettings.autoRecordCalls = on
        case "openInApp": NikxelSettings.openSummariesInApp = on
        case "appearance": NikxelSettings.appearance = text; window?.appearance = Self.appearance()
        case "waBotMode": app?.setWABotMode(item(text))
        case "captureMode": text == CaptureMode.notes.rawValue ? app?.setModeNotes() : app?.setModeMeeting()
        case "noteFormat": app?.setNoteFormat(item(text))
        case "avatarSize": app?.setAvatarSize(item((value as? NSNumber)?.doubleValue ?? Double(text) ?? 1))
        case "summaryTemplate": app?.selectTemplate(item(text))
        case "agent": if let agent = CodingAgent(rawValue: text) { NikxelSettings.connectedAgent = agent }
        case "language": NikxelSettings.language = text.isEmpty ? "auto" : text
        case "transcriptionLanguage": NikxelSettings.transcriptionLanguage = text
        case "summaryMinutes": NikxelSettings.summaryMinutes = number
        case "botMemoryDays": NikxelSettings.botMemoryDays = number
        case "waUnattendedMinutes": NikxelSettings.waUnattendedMinutes = max(1, min(120, number)); app?.refreshWAMenu()
        case "waQuietFrom": NikxelSettings.waQuietFrom = number; app?.refreshWAMenu()
        case "waQuietTo": NikxelSettings.waQuietTo = number; app?.refreshWAMenu()
        case "userName": if !text.isEmpty { NikxelSettings.userName = text }
        case "waOwnName": NikxelSettings.waOwnName = text
        case "userContext": NikxelSettings.userContext = text
        default: break
        }
    }

    private func run(_ name: String) {
        guard let app = app else { return }
        switch name {
        case "summarizeNow": app.summarizeNow()
        case "summarizeWeek": app.summarizeWeekNow()
        case "openNotes": app.openNotes()
        case "openMeetings": app.openMeetings()
        case "openDaily": app.openDaily()
        case "openUsage": app.openUsageFolder()
        case "regenerate": app.regenerateUnfinished()
        case "editTemplate":
            edit(SummaryTemplates.activeURL, "“\(SummaryTemplates.displayName(for: NikxelSettings.summaryTemplate))” template",
                 "Plain instructions, one per line, the way you’d tell a person: drop a section, add one, change the order, the length or the tone. Lines starting with # are ignored. Takes effect on your next recording; names, decisions and numbers still come only from the transcript.")
        case "aboutMeVoice": app.openAboutMe()
        case "openWhatsApp": app.openWhatsAppWindow()
        case "editPersonality":
            edit(app.botPersonalityURL(), "How I sound on WhatsApp", "The voice and rules I reply with. Write it the way you’d brief an assistant.")
        case "editTrusted":
            edit(WAContactLists.seedIfMissing(.trusted), "Trusted contacts", "One name per line, as it shows in WhatsApp. I can say more to these people. Lines starting with # are ignored.")
        case "editNeverReply":
            edit(WAContactLists.seedIfMissing(.neverReply), "Never reply to", "One name per line, as it shows in WhatsApp. I always leave these chats to you. Lines starting with # are ignored.")
        case "whatsappConnection": app.toggleWhatsAppConnection()
        case "connectGoogle": app.connectGoogleCalendar()
        case "connectSlack": app.connectSlack()
        case "connectReminders": app.connectAppleReminders()
        case "connectDashboard": app.connectDashboard()
        case "connectERP": app.connectERP()
        case "editSettings": app.editSettings()
        case "copyLogs": app.copyLogs()
        case "checkUpdates": app.checkForUpdates()
        case "setupWizard": app.openOnboarding()
        case "chooseProjects": chooseProjectsFolder()
        case "toggleRecording": app.toggleRecording()
        case "toggleMicMute": app.toggleMicMute()
        case "toggleVisibility": app.toggleVisibility()
        case "quit": app.quitApp()
        case "newTemplate": app.newTemplate()
        case "resetTemplate": app.resetActiveTemplate()
        case "deleteTemplate": app.deleteActiveTemplate()
        case "openTemplates": app.openTemplatesFolder()
        case "closeSummary": showSection(); push()
        case "replayTour": CoachTour.replay()
        case "openInBrowser": if let url = active?.file { NSWorkspace.shared.open(url) }
        case "revealSummary": if let url = active?.file { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        default: break
        }
    }

    private func edit(_ url: URL, _ title: String, _ help: String) {
        editing = (url, title, help)
        push()
    }

    /// What You → Appearance asks for; nil follows the system. The page's
    /// prefers-color-scheme (and the summary tabs') reads this.
    private static func appearance() -> NSAppearance? {
        switch NikxelSettings.appearance {
        case "light": return NSAppearance(named: .aqua)
        case "dark": return NSAppearance(named: .darkAqua)
        default: return nil
        }
    }

    private func chooseProjectsFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: NikxelSettings.projectsRoot)
        panel.message = "Pick the folder your git projects live in"
        guard let window = window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            NikxelSettings.projectsRoot = url.path
            self?.push()
        }
    }
}
