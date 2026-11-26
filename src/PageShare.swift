import AppKit
import AVFoundation
import Network

/// The Share button on summary pages. The page is a local file, so it can't
/// reach WhatsApp itself: it asks Nikxel over localhost, and Nikxel sends the
/// file from the WhatsApp window it already drives. "Copy" puts the file on
/// the clipboard, to paste into any chat or group by hand.
///
/// Any web page can call localhost, so every request carries a per-install
/// token that only pages Nikxel wrote contain, and only .html files under
/// ~/Documents/nikxel can be sent.
enum PageShare {
    static let port: UInt16 = 47120
    private static let queue = DispatchQueue(label: "nikxel.share")
    private static let ymd: DateFormatter = { let f = DateFormatter(); f.calendar = Calendar(identifier: .gregorian); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"; return f }()
    private static var listener: NWListener?

    // Voice input for the inline chat bar: recorded and transcribed on-device,
    // the same way the old Edit dialog did it. Audio never leaves the machine.
    private static let transcriber = Transcriber()
    private static var recorder: AVAudioRecorder?
    private static let voiceURL = URL(fileURLWithPath: NSHomeDirectory() + "/.nikxel/edits/voice.wav")

    private static func startVoice() -> Bool {
        try? FileManager.default.createDirectory(at: voiceURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16000,
                                        AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16]
        guard let r = try? AVAudioRecorder(url: voiceURL, settings: settings), r.record() else { return false }
        recorder = r; return true
    }

    static let token: String = {
        let url = URL(fileURLWithPath: NSHomeDirectory() + "/.nikxel/share_token")
        if let t = try? String(contentsOf: url, encoding: .utf8), t.count >= 32 { return t }
        let t = UUID().uuidString + UUID().uuidString
        try? t.write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return t
    }()

    /// Goes right before </body>. Marked, so a sent copy goes out without it.
    /// `editable` adds the Edit button (PageEdit) beside Share.
    static func widget(editable: Bool) -> String {
        widgetTemplate.replacingOccurrences(of: "__NIKXEL_TOKEN__", with: token)
            .replacingOccurrences(of: "__NIKXEL_CHAT__", with: editable ? chatBar : "")
    }

    /// The inline "tell Nikxel what to change" bar, docked at the bottom of an
    /// editable summary (replaces the old floating Edit dialog). Its CSS and JS
    /// live in the widget below, guarded by `#nx-chat` being present.
    private static let chatBar = #"<div id="nx-chat"><div class="nxc-log" hidden><div class="nxc-head"><button type="button" class="nxc-undo" title="Undo the last change">↺ Undo</button><button type="button" class="nxc-clear" title="Clear the chat">Clear</button></div><div class="nxc-msgs"></div></div><form class="nxc-form"><button type="button" class="nxc-mic" title="Speak" aria-label="Speak"><svg viewBox="0 0 24 24" width="17" height="17" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="9" y="2" width="6" height="12" rx="3"/><path d="M5 10a7 7 0 0 0 14 0M12 17v5"/></svg></button><input class="nxc-in" placeholder="Tell Nikxel what to change…" autocomplete="off"><button class="nxc-send" title="Send" aria-label="Send">↑</button></form></div>"#

    static func strip(_ html: String) -> String {
        html.replacingOccurrences(of: #"<!--nikxel-share-->[\s\S]*?<!--/nikxel-share-->"#, with: "", options: .regularExpression)
    }

    /// Re-inject the current widget into pages Nikxel already wrote, so old
    /// summaries gain new buttons (Assign) without being regenerated. Keeps
    /// each page's existing Edit affordance, and skips pages already upgraded.
    /// The widget carries a version marker (<!--nxw:N-->): bump N whenever its
    /// JS changes, or pages written before the change keep the old code.
    static func migrateWidgets() {
        let root = URL(fileURLWithPath: NSHomeDirectory() + "/Documents/nikxel")
        guard let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil),
              let re = try? NSRegularExpression(pattern: "<!--nikxel-share-->[\\s\\S]*?<!--/nikxel-share-->") else { return }
        for case let url as URL in en where url.pathExtension == "html" {
            guard let html = try? String(contentsOf: url, encoding: .utf8),
                  html.contains("<!--nikxel-share-->"), !html.contains("<!--nxw:2-->") else { continue }
            let block = widget(editable: html.contains("nx-edit") || html.contains("nx-chat"))
            let out = re.stringByReplacingMatches(in: html, range: NSRange(html.startIndex..., in: html),
                                                  withTemplate: NSRegularExpression.escapedTemplate(for: block))
            try? out.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    // MARK: - Server

    static func start() {
        _ = token
        let params = NWParameters.tcp
        params.acceptLocalOnly = true
        params.requiredInterfaceType = .loopback
        guard let l = try? NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!) else {
            cblog("PageShare: port \(port) is busy — Share buttons won't work"); return
        }
        listener = l
        queue.async { migrateWidgets() }   // give existing pages the Assign button
        l.newConnectionHandler = { conn in
            conn.start(queue: queue)
            conn.receive(minimumIncompleteLength: 1, maximumLength: 16384) { data, _, _, _ in
                let req = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                let reply = { (body: [String: Any]) in
                    let json = (try? JSONSerialization.data(withJSONObject: body)) ?? Data("{}".utf8)
                    var head = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nAccess-Control-Allow-Origin: *\r\n"
                    head += "Content-Length: \(json.count)\r\nConnection: close\r\n\r\n"
                    conn.send(content: Data(head.utf8) + json, completion: .contentProcessed { _ in conn.cancel() })
                }
                if let body = handle(req, later: reply) { reply(body) }
            }
        }
        l.start(queue: queue)
    }

    /// Nil when the answer comes later through `later` (/dashboard, off this queue).
    private static func handle(_ req: String, later: @escaping ([String: Any]) -> Void) -> [String: Any]? {
        let q = { (k: String) in GoogleAuth.queryParam(request: req, key: k) }
        guard q("t") == token else { return ["error": "This page can only be shared from the Mac that made it."] }
        let route = req.split(separator: " ").dropFirst().first?.split(separator: "?").first ?? ""
        guard let file = allowedFile(q("path")) else { return ["error": "Only Nikxel's own pages can be shared."] }

        switch route {
        case "/edit":
            guard PageEdit.editable(file) else { return ["error": "This summary can't be edited."] }
            if q("undo") == "1" {
                let ok = (try? PageEdit.undo(file)) ?? false
                return ["note": ok ? "Undone — back to before the last change." : "Nothing to undo."]
            }
            guard let text = q("text"), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return ["error": "Nothing to change."] }
            // apply() runs the agent (slow) or the stat hook; answer later, off the listener queue.
            DispatchQueue.global().async {
                do { later(["note": try PageEdit.apply(text, to: file)]) }
                catch { later(["error": error.localizedDescription]) }
            }
            return nil
        case "/mic":
            guard PageEdit.editable(file) else { return ["error": "This summary can't be edited."] }
            if q("do") == "start" {
                var ok = false
                DispatchQueue.main.sync { ok = startVoice() }
                return ok ? ["ok": true] : ["error": "Couldn't use the microphone."]
            }
            DispatchQueue.main.async {
                recorder?.stop(); recorder = nil
                transcriber.transcribe(audioURL: voiceURL, outputFormat: .txt) { result in
                    let heard = (try? result.get()).flatMap { try? String(contentsOf: $0, encoding: .utf8) }?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    later(["text": heard])
                }
            }
            return nil
        case "/task":
            // A ticked box on a day page. The .md is what tomorrow's summary
            // and the morning card read, so "— done" there drops the task.
            guard let i = q("i").flatMap(Int.init), DayPage.tick(file, index: i, done: q("done") == "1") else {
                return ["error": "Couldn't update that task."]
            }
            return ["ok": true]
        case "/name":
            // A summary still named by its timestamp: suggest a title, or rename to the one picked.
            guard PageEdit.editable(file) else { return ["error": "This summary can't be renamed."] }
            if let to = q("to") {
                do { return ["url": try NoteName.rename(file, to: to, editsDir: PageEdit.backups).absoluteString] }
                catch { return ["error": error.localizedDescription] }
            }
            DispatchQueue.global().async {
                later(PageEdit.suggestName(for: file).map { ["name": $0] } ?? ["error": "Nikxel couldn't think of a name — type one."])
            }
            return nil
        case "/version":
            let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            return ["v": date?.timeIntervalSince1970 ?? 0]
        case "/copy":
            let tmp = URL(fileURLWithPath: NSHomeDirectory() + "/.nikxel/share")
            try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            let out = tmp.appendingPathComponent(file.lastPathComponent)
            guard let html = try? String(contentsOf: file, encoding: .utf8),
                  (try? strip(html).write(to: out, atomically: true, encoding: .utf8)) != nil else {
                return ["error": "Couldn't read the page."]
            }
            DispatchQueue.main.sync {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.writeObjects([out as NSURL])
            }
            return ["ok": true]
        case "/chats", "/send":
            guard NikxelSettings.whatsappConnected else { return ["error": "WhatsApp isn't connected in Nikxel."] }
            var result: [String: Any] = [:]
            if route == "/chats" {
                ChatbotEngine.shared.withPollingHeld {
                    result = ["chats": ChromeWhatsApp.searchChats(q("q") ?? "")]; return true
                }
                return result
            }
            guard let to = q("to"), !to.isEmpty,
                  let html = try? String(contentsOf: file, encoding: .utf8) else { return ["error": "Nothing to send."] }
            ChatbotEngine.shared.withPollingHeld {
                guard ChromeWhatsApp.openChatBySearch(to) else {
                    result = ["error": "Couldn't open \(to)'s chat in WhatsApp."]; return true
                }
                result = ChromeWhatsApp.sendFile(named: file.lastPathComponent, data: Data(strip(html).utf8), type: "text/html")
                    ? ["ok": true] : ["error": "WhatsApp didn't take the file."]
                return true
            }
            cblog("PageShare: \(file.lastPathComponent) → '\(to)': \(result["ok"] != nil ? "sent" : "\(result["error"] ?? "")")")
            return result
        case "/client":
            // Render the client-facing page from the meeting's "## Client
            // Summary" section and hand back its file URL. The page carries its
            // own Share buttons, so the user previews it, then sends it.
            let mdURL = file.deletingPathExtension().appendingPathExtension("md")
            guard let md = try? String(contentsOf: mdURL, encoding: .utf8),
                  let clientMd = NotePage.clientMarkdown(from: md) else {
                return ["error": "This summary has no client version."]
            }
            let clientFile = file.deletingPathExtension().appendingPathExtension("client").appendingPathExtension("html")
            guard (try? NotePage.html(from: clientMd).write(to: clientFile, atomically: true, encoding: .utf8)) != nil else {
                return ["error": "Couldn't build the client summary."]
            }
            return ["url": clientFile.absoluteString]
        case "/coach":
            // A What's new tour step for this page (the meeting the window just opened for it), once.
            let mine = file.resolvingSymlinksInPath().path
            let step: [String: Any]? = DispatchQueue.main.sync {
                guard let c = DashboardWindowController.coach, c.file.resolvingSymlinksInPath().path == mine else { return nil }
                DashboardWindowController.coach = nil
                return c.step
            }
            return ["step": step ?? NSNull()]
        case "/coach-done":
            DashboardWindowController.tourResume(skip: q("skip") == "1")
            return ["ok": true]
        case "/projects", "/share-project":
            // A meeting page's Share to project dialog (list + exact body), then its Send.
            ProjectShare.handle(project: route == "/projects" ? nil : q("project") ?? "", file: file, later: later)
            return nil
        case "/dashboard-state", "/dashboard":
            // The daily page's Send bar. <stem>.sent.json beside it remembers what was crossed out.
            guard file.deletingLastPathComponent().lastPathComponent == "daily" else { return ["error": "Only a daily summary can be sent to the dashboard."] }
            let stem = file.deletingPathExtension().lastPathComponent
            let sentURL = file.deletingLastPathComponent().appendingPathComponent("\(stem).sent.json")
            if route == "/dashboard-state" {
                let sent = (try? Data(contentsOf: sentURL)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
                return ["paired": CloudSync.token != nil, "skip": sent["skip"] as? [String] ?? [], "sentAt": sent["sentAt"] as? Double ?? NSNull()]
            }
            guard CloudSync.token != nil else { return ["error": "Connect Nikxel to the dashboard first (menu → Connect to Dashboard…)"] }
            guard let md = try? String(contentsOf: file.deletingPathExtension().appendingPathExtension("md"), encoding: .utf8) else {
                return ["error": "Couldn't read this day's summary."]
            }
            let skip = (q("skip") ?? "").split(separator: ",").map(String.init)
            let resend = FileManager.default.fileExists(atPath: sentURL.path)
            if !resend, CloudSync.dayItems(fromDailySummary: md).items.allSatisfy({ skip.contains($0.id) }) { return ["error": "Nothing left to send."] }
            // Measured tiles so the dashboard shows the same numbers as this page:
            // the day's stats, with any owner <!--stat--> marker overriding them.
            var stats = CloudSync.statsFromMarkers(md)
            if let d = Self.ymd.date(from: stem), let s = DayLogger.current?.dayStats(for: d) {
                if stats["computer"] == nil, s.activeSeconds >= 60 { stats["computer"] = Int((s.activeSeconds / 60).rounded()) }
                if stats["coding"] == nil, s.codingSeconds >= 60 { stats["coding"] = Int((s.codingSeconds / 60).rounded()) }
                if stats["meetings"] == nil, s.meetings > 0 { stats["meetings"] = s.meetings }
                if stats["messages"] == nil, s.messages > 0 { stats["messages"] = s.messages }
            }
            // pushDay blocks for up to 20s; keep the listener free meanwhile.
            DispatchQueue.global().async {
                guard CloudSync.pushDay(summary: md, day: stem, skip: Set(skip), stats: stats.isEmpty ? nil : stats, allowEmpty: resend) else { return later(["error": "Couldn't reach the dashboard. Try again."]) }
                if let data = try? JSONSerialization.data(withJSONObject: ["skip": skip, "sentAt": Date().timeIntervalSince1970] as [String: Any]) {
                    try? data.write(to: sentURL, options: .atomic)
                }
                later(["ok": true])
            }
            return nil
        case "/erp":
            // Just whether Assign buttons should show. Matching + create happen
            // server-side on /assign, so the page needs no roster.
            return ["connected": ERP.isConnected]
        case "/assign":
            guard ERP.isConnected else { return ["error": "Connect your ERP under Connections in Nikxel first."] }
            guard ERP.hasLiveSession() else {
                return ["error": "Your ERP session has ended. Reconnect it under Connections in Nikxel, then try again."]
            }
            // The page sends the full action-item text; we make a short title
            // and a context-rich description, since the assignee may not have
            // been in the meeting. Only the title is required in Odoo.
            guard let item = q("title"), !item.isEmpty else { return ["error": "No task text."] }
            let who = q("who") ?? ""
            let uid = who.isEmpty ? nil : ERP.matchUser(who, in: ERP.assignableUsers())?.id
            let deadline = (q("due")).flatMap { $0.isEmpty ? nil : $0 + " 17:00:00" }  // date → datetime
            let title = ERP.shortTitle(item)
            // Prefer the rich brief Nikxel already wrote for software tasks;
            // fall back to the plain task + meeting origin for the rest.
            let mdURL = file.deletingPathExtension().appendingPathExtension("md")
            let desc = ERP.briefFromAgentPrompts(item: item, mdURL: mdURL)
                ?? ERP.taskDescription(item: item, context: meetingContext(file))
            guard let tid = ERP.createTask(title: title, descriptionHTML: desc,
                                           assigneeUserID: uid, projectID: nil, deadline: deadline) else {
                return ["error": "ERP didn't create the task."]
            }
            cblog("ERP: created task \(tid) — \(title.prefix(60))")
            return ["url": ERP.taskURL(id: tid)]
        default:
            return ["error": "Unknown request."]
        }
    }

    /// A one-line meeting context for a task description: the summary's
    /// headline and the meeting date, so an assignee who wasn't there has a
    /// pointer to what it was about.
    private static func meetingContext(_ file: URL) -> String {
        let stem = file.deletingPathExtension().lastPathComponent        // 2026-11-12-103105
        let date = NoteName.stamp(stem).prefix(10)
        var headline = ""
        if let html = try? String(contentsOf: file, encoding: .utf8),
           let r = html.range(of: #"<h1[^>]*>[\s\S]*?</h1>"#, options: .regularExpression) {
            headline = String(html[r])
                .replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if headline.isEmpty { return "Came out of a team meeting on \(date)." }
        return "Came out of a team meeting on \(date): \(headline)"
    }

    /// The page's own path, if it's an .html file Nikxel writes.
    private static func allowedFile(_ path: String?) -> URL? {
        guard let path = path else { return nil }
        let root = URL(fileURLWithPath: NSHomeDirectory() + "/Documents/nikxel").resolvingSymlinksInPath().path + "/"
        var url = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        guard url.path.hasPrefix(root), url.pathExtension == "html" else { return nil }
        // A page still open under its date name after it was renamed: its
        // buttons carry the old path, so follow it to "<name> <stamp>.html".
        if !FileManager.default.fileExists(atPath: url.path) {
            let stem = url.deletingPathExtension().lastPathComponent, dir = url.deletingLastPathComponent()
            guard NoteName.isUnnamed(stem),
                  let renamed = (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?.first(where: { $0.hasSuffix(" \(stem).html") })
            else { return nil }
            url = dir.appendingPathComponent(renamed)
        }
        return url
    }

    // MARK: - The button

    /// Same markup in windows/src/main/system/pageShare.ts.
    private static let widgetTemplate = #"""
<!--nikxel-share--><!--nxw:2--><div id="nx-share"><button class="nx-btn nx-sharebtn" type="button">Share</button><div class="nx-pop" hidden>
<button class="nx-copy" type="button">Copy file</button><div class="nx-or">or send on WhatsApp to</div>
<input class="nx-q" placeholder="Search a chat or contact"><div class="nx-list"></div><div class="nx-msg"></div></div></div>
__NIKXEL_CHAT__
<style>
#nx-share{position:fixed;right:20px;bottom:20px;z-index:99;font:14px/1.4 system-ui,-apple-system,"Segoe UI",sans-serif;color:#1d1d1f}
#nx-share .nx-btn{background:#1d1d1f;color:#fff;border:0;border-radius:999px;padding:10px 18px;font:inherit;font-weight:600;cursor:pointer;box-shadow:0 4px 16px rgba(0,0,0,.18)}
#nx-chat{position:fixed;left:50%;transform:translateX(-50%);bottom:18px;width:min(720px,calc(100vw - 32px));z-index:98;font:14px/1.45 system-ui,-apple-system,"Segoe UI",sans-serif}
#nx-chat .nxc-log{max-height:44vh;overflow:auto;margin-bottom:8px;background:rgba(255,255,255,.66);-webkit-backdrop-filter:blur(20px) saturate(1.7);backdrop-filter:blur(20px) saturate(1.7);border:1px solid rgba(0,0,0,.08);border-radius:18px;box-shadow:0 12px 44px rgba(0,0,0,.18)}
#nx-chat .nxc-log[hidden]{display:none}
#nx-chat .nxc-head{position:sticky;top:0;display:flex;justify-content:space-between;gap:8px;padding:8px 12px;background:inherit;border-bottom:1px solid rgba(0,0,0,.06)}
#nx-chat .nxc-head button{border:0;background:none;color:#6e6e73;font:inherit;font-size:12px;cursor:pointer;padding:3px 8px;border-radius:7px}
#nx-chat .nxc-head button:hover{background:rgba(0,0,0,.06);color:#1d1d1f}
#nx-chat .nxc-msgs{display:flex;flex-direction:column;gap:8px;padding:12px}
#nx-chat .nxc-msg{max-width:85%;padding:8px 12px;border-radius:14px;white-space:pre-wrap;font-size:13.5px}
#nx-chat .nxc-me{align-self:flex-end;background:#1d1d1f;color:#fff;border-bottom-right-radius:5px}
#nx-chat .nxc-bot{align-self:flex-start;background:rgba(0,0,0,.06);color:#1d1d1f;border-bottom-left-radius:5px}
#nx-chat .nxc-form{display:flex;align-items:center;gap:4px;padding:5px 5px 5px 8px;background:rgba(255,255,255,.58);-webkit-backdrop-filter:blur(20px) saturate(1.7);backdrop-filter:blur(20px) saturate(1.7);border:1px solid rgba(0,0,0,.1);border-radius:999px;box-shadow:0 8px 30px rgba(0,0,0,.16)}
#nx-chat .nxc-in{flex:1;min-width:0;border:0;outline:0;background:transparent;font:inherit;color:#1d1d1f;padding:9px 6px}
#nx-chat .nxc-mic,#nx-chat .nxc-send{width:34px;height:34px;border:0;border-radius:50%;cursor:pointer;flex:none;display:grid;place-items:center}
#nx-chat .nxc-mic{background:transparent;color:#6e6e73}
#nx-chat .nxc-mic:hover{background:rgba(0,0,0,.08)}
#nx-chat .nxc-mic.rec{background:#ff3b30;color:#fff;animation:nxc-pulse 1.3s infinite}
#nx-chat .nxc-send{background:#5e5ce6;color:#fff;font:17px/1 system-ui}
#nx-chat .nxc-send:disabled{opacity:.5;cursor:default}
@keyframes nxc-pulse{0%{box-shadow:0 0 0 0 rgba(255,59,48,.5)}100%{box-shadow:0 0 0 10px rgba(255,59,48,0)}}
body.nx-has-chat{padding-bottom:104px}
@media (prefers-color-scheme:dark){
#nx-chat .nxc-log{background:rgba(28,28,32,.62);border-color:rgba(255,255,255,.1)}
#nx-chat .nxc-head{border-bottom-color:rgba(255,255,255,.08)}
#nx-chat .nxc-head button{color:#a0a0a8}
#nx-chat .nxc-head button:hover{background:rgba(255,255,255,.1);color:#fff}
#nx-chat .nxc-bot{background:rgba(255,255,255,.12);color:#f5f5f7}
#nx-chat .nxc-form{background:rgba(36,36,40,.55);border-color:rgba(255,255,255,.14)}
#nx-chat .nxc-in{color:#f5f5f7}
#nx-chat .nxc-mic{color:#a0a0a8}
#nx-chat .nxc-mic:hover{background:rgba(255,255,255,.1)}
}
@media print{#nx-chat{display:none}}
#nx-share .nx-pop{position:absolute;right:0;bottom:52px;width:290px;background:#fff;border-radius:14px;padding:12px;box-shadow:0 10px 40px rgba(0,0,0,.22)}
#nx-share .nx-pop[hidden]{display:none}
#nx-share .nx-copy{width:100%;padding:9px;border:1px solid #d2d2d7;border-radius:9px;background:#f5f5f7;font:inherit;cursor:pointer}
#nx-share .nx-or{margin:12px 2px 6px;color:#6e6e73;font-size:12px}
#nx-share .nx-q{width:100%;box-sizing:border-box;padding:8px 10px;border:1px solid #d2d2d7;border-radius:9px;font:inherit}
#nx-share .nx-list{max-height:230px;overflow:auto;margin-top:6px}
#nx-share .nx-list button{display:block;width:100%;text-align:left;padding:8px 10px;border:0;border-radius:8px;background:none;font:inherit;color:inherit;cursor:pointer}
#nx-share .nx-list button:hover{background:#f0f0f3}
#nx-share .nx-msg{margin-top:8px;font-size:12px;color:#6e6e73}
#nx-share .nx-msg:empty{display:none}
@media print{#nx-share{display:none}}
#nx-name{display:flex;flex-wrap:wrap;align-items:center;gap:8px;margin:0 0 18px;padding:10px 12px;border:1px solid rgba(94,92,230,.25);border-radius:14px;background:rgba(94,92,230,.06);font:14px/1.4 system-ui,-apple-system,"Segoe UI",sans-serif}
#nx-name .nxn-l{font-weight:600;color:#5e5ce6}
#nx-name .nxn-in{flex:1;min-width:180px;padding:8px 10px;border:1px solid #d2d2d7;border-radius:9px;font:inherit;background:#fff;color:#1d1d1f}
#nx-name button{border:0;border-radius:999px;padding:8px 14px;font:inherit;font-weight:600;cursor:pointer}
#nx-name .nxn-ok{background:#1d1d1f;color:#fff}
#nx-name button:disabled{opacity:.5;cursor:default}
#nx-name .nxn-msg{width:100%;font-size:12px;color:#6e6e73}
#nx-name .nxn-msg:empty{display:none}
@media (prefers-color-scheme:dark){#nx-name .nxn-in{background:#1c1c1e;color:#f5f5f7;border-color:#3a3a3c}#nx-name .nxn-ok{background:#f5f5f7;color:#1d1d1f}}
@media print{#nx-name{display:none}}
li.task .nx-assign{margin-left:8px;vertical-align:middle;background:#1d1d1f;color:#fff;border:0;border-radius:999px;padding:3px 11px;font:600 12px/1 system-ui,-apple-system,"Segoe UI",sans-serif;cursor:pointer;opacity:.85}
li.task .nx-assign:hover{opacity:1}
li.task .nx-assign:disabled{opacity:.6;cursor:default}
li.task .nx-assign.done{background:#34c759;opacity:1}
@media print{li.task .nx-assign{display:none}}
</style>
<script>(function(){
  var T = "__NIKXEL_TOKEN__", P = "http://127.0.0.1:47120/";
  var path = decodeURIComponent(location.pathname).replace(/^\/([A-Za-z]:)/, "$1");
  var root = document.getElementById("nx-share"), pop = root.querySelector(".nx-pop");
  var q = root.querySelector(".nx-q"), list = root.querySelector(".nx-list"), msg = root.querySelector(".nx-msg");
  function call(route, extra) {
    var p = new URLSearchParams(extra || {}); p.set("t", T); p.set("path", path);
    return fetch(P + route + "?" + p).then(function (r) { return r.json(); },
      function () { return { error: "Open Nikxel to share." }; });
  }
  function say(t) { msg.textContent = t || ""; }
  var timer, asked = 0;
  function load() {
    var n = ++asked; say("Looking…");
    call("chats", { q: q.value.trim() }).then(function (r) {
      if (n !== asked) return;
      list.innerHTML = ""; say(r.error || (r.chats.length ? "" : "No chats found."));
      (r.chats || []).forEach(function (name) {
        var b = document.createElement("button"); b.type = "button"; b.textContent = name;
        b.onclick = function () {
          if (!confirm("Send this page to " + name + " on WhatsApp?")) return;
          say("Sending to " + name + "…");
          call("send", { to: name }).then(function (r) { say(r.error || "Sent to " + name + " ✓"); });
        };
        list.appendChild(b);
      });
    });
  }
  // After Edit, watch the file and reload when the chat window changes it.
  // sessionStorage keeps the watch going across that reload.
  var v = 0;
  function watch() {
    call("version").then(function (r) {
      // No answer (Nikxel restarting): keep asking rather than give up.
      if (r.v && v && r.v !== v) { location.reload(); return; }
      if (r.v) v = r.v;
      setTimeout(watch, 2000);
    });
  }
  try { if (sessionStorage.getItem("nx-editing")) watch(); } catch (e) {}
  // Inline "tell Nikxel what to change" bar (replaces the old Edit dialog).
  // Talks to /edit over the same bridge; the chat log survives the reload that
  // shows each applied change, via sessionStorage.
  var chat = document.getElementById("nx-chat");
  if (chat) {
    document.body.classList.add("nx-has-chat");
    var clog = chat.querySelector(".nxc-log"), cmsgs = chat.querySelector(".nxc-msgs"), cin = chat.querySelector(".nxc-in");
    var csend = chat.querySelector(".nxc-send"), cmic = chat.querySelector(".nxc-mic");
    var cundo = chat.querySelector(".nxc-undo"), cclear = chat.querySelector(".nxc-clear"), LK = "nx-chatlog";
    var cbubble = function (role, text) {
      var d = document.createElement("div"); d.className = "nxc-msg " + (role === "me" ? "nxc-me" : "nxc-bot");
      d.textContent = text; cmsgs.appendChild(d); clog.hidden = false; clog.scrollTop = clog.scrollHeight; return d;
    };
    var cstore = function (role, text) { try { var a = JSON.parse(sessionStorage.getItem(LK) || "[]"); a.push([role, text]); sessionStorage.setItem(LK, JSON.stringify(a.slice(-20))); } catch (e) {} };
    try { JSON.parse(sessionStorage.getItem(LK) || "[]").forEach(function (m) { cbubble(m[0], m[1]); }); } catch (e) {}
    var cbusy = false, rec = false;
    var csync = function () { csend.disabled = cbusy || !cin.value.trim(); cin.disabled = cbusy; cmic.disabled = cbusy; };
    var creload = function () { setTimeout(function () { location.reload(); }, 600); };
    var crun = function (text) {
      cbubble("me", text); cstore("me", text);
      var w = cbubble("bot", "…"); cbusy = true; csync();
      call("edit", { text: text }).then(function (r) {
        var note = (r && (r.note || r.error)) || "Something went wrong.";
        w.textContent = note; cstore("bot", note); cbusy = false; csync();
        if (r && r.note) creload();   // applied — reload to show it; the log survives in sessionStorage
      });
    };
    chat.querySelector(".nxc-form").onsubmit = function (e) { e.preventDefault(); var t = cin.value.trim(); if (!t || cbusy) return; cin.value = ""; csync(); crun(t); };
    cin.oninput = csync;
    cundo.onclick = function () {
      if (cbusy) return; cbusy = true; csync();
      call("edit", { undo: "1" }).then(function (r) {
        var note = (r && (r.note || r.error)) || "Nothing to undo."; cbubble("bot", note); cstore("bot", note);
        cbusy = false; csync(); if (r && r.note && r.note.indexOf("Nothing") < 0) creload();
      });
    };
    cclear.onclick = function () { cmsgs.innerHTML = ""; clog.hidden = true; try { sessionStorage.removeItem(LK); } catch (e) {} };
    // Voice: recorded and transcribed on-device by Nikxel (no audio leaves the machine).
    cmic.onclick = function () {
      if (cbusy) return;
      if (!rec) {
        call("mic", { do: "start" }).then(function (r) {
          if (r && r.ok) { rec = true; cmic.classList.add("rec"); cin.placeholder = "Listening… tap the mic to stop"; }
          else cbubble("bot", (r && r.error) || "Couldn't use the microphone.");
        });
        return;
      }
      rec = false; cmic.classList.remove("rec"); cin.placeholder = "Tell Nikxel what to change…";
      cbusy = true; csync();
      call("mic", { do: "stop" }).then(function (r) {
        cbusy = false; csync();
        var heard = (r && r.text) || "";
        if (heard) { cin.value = (cin.value ? cin.value + " " : "") + heard; cin.focus(); csync(); }
      });
    };
    csync();
    // On open: a quick hand-drawn arrow from the title down to the chat bar, so
    // people notice they can edit. Draws in, holds, fades out (~2.5s total).
    function cHint() {
      if (window.__nxCoach) return;   // a tour step is showing on this page
      try {
        var titleEl = document.querySelector(".date") || document.querySelector("h1") || document.querySelector("main");
        if (!titleEl) return;
        var tr = titleEl.getBoundingClientRect(), cr = chat.getBoundingClientRect(), NS = "http://www.w3.org/2000/svg";
        var sx = tr.left, sy = tr.bottom + 4, ex = cr.left + 26, ey = cr.top - 14;
        var leftX = Math.max(8, Math.min(sx, ex) - 90);    // bow well out into the left gutter
        var svg = document.createElementNS(NS, "svg");
        svg.setAttribute("width", innerWidth); svg.setAttribute("height", innerHeight);
        svg.style.cssText = "position:fixed;inset:0;z-index:97;pointer-events:none";
        svg.innerHTML = '<defs><marker id="nxc-ah" markerWidth="10" markerHeight="10" refX="6.5" refY="5" orient="auto"><path d="M0,0 L10,5 L0,10 z" fill="#5e5ce6"/></marker></defs>';
        var p = document.createElementNS(NS, "path");
        p.setAttribute("d", "M " + sx + " " + sy + " C " + leftX + " " + (sy + 50) + " " + leftX + " " + (ey - 70) + " " + ex + " " + ey);
        p.setAttribute("fill", "none"); p.setAttribute("stroke", "#5e5ce6"); p.setAttribute("stroke-width", "3");
        p.setAttribute("stroke-linecap", "round"); p.setAttribute("marker-end", "url(#nxc-ah)");
        svg.appendChild(p); document.body.appendChild(svg);
        var cap = document.createElement("div"); cap.textContent = "Edit anything here";
        cap.style.cssText = "position:fixed;left:" + ex + "px;top:" + (ey - 46) + "px;z-index:97;pointer-events:none;background:#5e5ce6;color:#fff;font:600 12px/1 system-ui,-apple-system,sans-serif;padding:6px 11px;border-radius:999px;white-space:nowrap;box-shadow:0 6px 20px rgba(94,92,230,.45)";
        document.body.appendChild(cap);
        var reduce = matchMedia("(prefers-reduced-motion: reduce)").matches, len = p.getTotalLength();
        p.style.strokeDasharray = len; p.style.strokeDashoffset = reduce ? 0 : len;
        if (!reduce) p.animate([{ strokeDashoffset: len }, { strokeDashoffset: 0 }], { duration: 850, fill: "forwards", easing: "ease-out" });
        cap.animate([{ opacity: 0, transform: "translateY(6px)" }, { opacity: 1, transform: "translateY(0)" }], { duration: 400, delay: reduce ? 0 : 500, fill: "both", easing: "ease-out" });
        setTimeout(function () {
          [svg, cap].forEach(function (el) { var f = el.animate([{ opacity: 1 }, { opacity: 0 }], { duration: 500, fill: "forwards" }); f.onfinish = function () { el.remove(); }; });
        }, 2500);
      } catch (e) {}
    }
    setTimeout(cHint, 500);   // let layout and fonts settle first
  }
  document.querySelectorAll("input.nx-todo").forEach(function (b) {
    b.disabled = false;
    b.onchange = function () {
      call("task", { i: b.getAttribute("data-i"), done: b.checked ? "1" : "0" }).then(function (r) {
        if (r.error) { b.checked = !b.checked; alert(r.error); }
      });
    };
  });
  root.querySelector(".nx-sharebtn").onclick = function () {
    pop.hidden = !pop.hidden; if (!pop.hidden) { q.focus(); load(); }
  };
  q.oninput = function () { clearTimeout(timer); timer = setTimeout(load, 500); };
  root.querySelector(".nx-copy").onclick = function () {
    call("copy").then(function (r) { say(r.error || "Copied. Paste it into any WhatsApp chat or group."); });
  };
  document.addEventListener("click", function (e) { if (!root.contains(e.target)) pop.hidden = true; });

  // --- "Preview & share client summary": build the client-facing page from
  // this meeting's Client Summary section and open it (it has its own Share).
  var clientBtn = document.querySelector(".nx-client");
  if (clientBtn) clientBtn.onclick = function () {
    var old = clientBtn.textContent; clientBtn.disabled = true; clientBtn.textContent = "Preparing…";
    call("client").then(function (r) {
      clientBtn.disabled = false; clientBtn.textContent = old;
      if (r && r.url) window.open(r.url, "_blank");
      else alert((r && r.error) || "Couldn't build the client summary.");
    });
  };

  // A named summary ("<name> <stamp>.html") shows its name on the tab, not the heading's date.
  var named = /^(.+) \d{4}-\d\d-\d\d-\d{4,6}\.html$/.exec(path.split(/[\\/]/).pop());
  if (named) document.title = named[1];

  // --- A summary still named by its timestamp: Nikxel suggests a title on
  // the page; the user saves it as is or edits it first.
  var NK = "nx-named:" + path, kept = false;
  try { kept = !!localStorage.getItem(NK); } catch (e) {}
  if (/^\d{4}-\d\d-\d\d-\d{6}\.html$/.test(path.split(/[\\/]/).pop()) && !kept) {
    var nb = document.createElement("div"); nb.id = "nx-name";
    nb.innerHTML = '<span class="nxn-l">Name this file</span><input class="nxn-in" placeholder="Nikxel is thinking of a name…" disabled>'
      + '<button type="button" class="nxn-ok" disabled>Save name</button><span class="nxn-msg"></span>';
    var nmain = document.querySelector("main") || document.body; nmain.insertBefore(nb, nmain.firstChild);
    var nin = nb.querySelector(".nxn-in"), nok = nb.querySelector(".nxn-ok"), nmsg = nb.querySelector(".nxn-msg");
    call("name").then(function (r) {
      nin.disabled = nok.disabled = false; nin.placeholder = "Type a name";
      if (r.name) nin.value = r.name; else nmsg.textContent = r.error || "";
    });
    var nsave = function () {
      var v = nin.value.trim(); if (!v) { nin.focus(); return; }
      nok.disabled = true; nmsg.textContent = "Renaming…";
      call("name", { to: v }).then(function (r) {
        if (r.url) {
          location.replace(r.url);
          // Renamed on disk either way; if this page wasn't swapped for the new one, say so instead of hanging.
          setTimeout(function () { nin.disabled = true; nok.remove(); nmsg.textContent = "Renamed to \u201c" + v + "\u201d. It shows under that name in Library."; }, 2000);
          return;
        }
        nok.disabled = false; nmsg.textContent = r.error || "Couldn't rename.";
      });
    };
    nok.onclick = nsave;
    nin.onkeydown = function (e) { if (e.key === "Enter") nsave(); };
  }

  // --- "Push to dashboard": one click. Nikxel picks the project it thinks these minutes are
  // from (already pushed: where they went); the dropdown changes it. See what's sent shows exactly
  // what goes (the minutes minus the client summary).
  var projBtn = document.querySelector(".nx-project");
  if (projBtn) (function () {
    var box = projBtn.parentNode, note = box.querySelector("p");
    function el(tag, css, text) { var e = document.createElement(tag); if (css) e.style.cssText = css; if (text != null) e.textContent = text; return e; }
    var hhmm = function (s) { var d = new Date(s * 1000); return d.toLocaleDateString(undefined, { day: "numeric", month: "short" }) + ", " + ("0" + d.getHours()).slice(-2) + ":" + ("0" + d.getMinutes()).slice(-2); };
    projBtn.textContent = "Push to dashboard"; projBtn.disabled = true;
    if (note) note.textContent = "Finding the project…";
    call("projects").then(function (r) {
      if (!r || r.error) { if (note) note.textContent = (r && r.error) || "Couldn't reach Nikxel."; return; }
      if (!r.paired) { if (note) note.textContent = "Connect Nikxel to your organization first, under Organization in the Nikxel window."; return; }
      if (!r.projects || !r.projects.length) { if (note) note.textContent = "You're not on any project yet. Make one under Organization → Projects."; return; }
      var pick = el("select", "font:600 14px/1 var(--sans);padding:9px 10px;border-radius:10px;border:1px solid var(--line);background:var(--surface);color:var(--ink);max-width:260px");
      pick.setAttribute("aria-label", "Project");
      if (!r.suggested) pick.appendChild(el("option", "", "Pick a project")).value = "";
      r.projects.forEach(function (p) { var o = el("option", "", p.name); o.value = p.id; o.selected = p.id === r.suggested; pick.appendChild(o); });
      box.insertBefore(pick, projBtn);
      var peek = el("button", "border:0;background:none;color:var(--muted);font:500 13px var(--sans);text-decoration:underline;cursor:pointer;padding:0", "See what's sent");
      peek.type = "button"; box.insertBefore(peek, projBtn.nextSibling);
      function status() {
        var name = pick.options[pick.selectedIndex] && pick.value ? pick.options[pick.selectedIndex].textContent : "";
        projBtn.disabled = !pick.value;
        if (!note) return;
        if (r.sent && r.sent.project === pick.value) note.textContent = "Pushed to " + (r.sent.name || name) + " on " + hhmm(r.sent.at) + " ✓ Push again to update it.";
        else if (pick.value && pick.value === r.suggested && r.why) note.textContent = "Suggested: " + r.why + " Not right? Pick another.";
        else note.textContent = pick.value ? "Sends these minutes to " + name + ", without the client summary or transcript." : "Which project is this meeting from?";
      }
      pick.onchange = status; status();
      projBtn.onclick = function () {
        projBtn.disabled = true; pick.disabled = true; if (note) note.textContent = "Pushing…";
        call("share-project", { project: pick.value }).then(function (s) {
          projBtn.disabled = false; pick.disabled = false;
          if (s && s.ok) { r.sent = s.sent; status(); }
          else if (note) note.textContent = (s && s.error) || "Couldn't push it.";
        });
      };
      peek.onclick = function () {
        var dlg = el("dialog", "width:min(560px,calc(100vw - 32px));box-sizing:border-box;border:0;border-radius:16px;padding:20px;font:14px/1.45 system-ui,-apple-system,'Segoe UI',sans-serif;color:#1d1d1f;background:#fff;box-shadow:0 20px 60px rgba(0,0,0,.3)");
        dlg.onclose = function () { dlg.remove(); };
        dlg.appendChild(el("h3", "margin:0 0 10px;font-size:16px", "Exactly what's sent"));
        dlg.appendChild(el("pre", "max-height:60vh;overflow:auto;white-space:pre-wrap;margin:0 0 14px;padding:10px 12px;background:#f5f5f7;border-radius:10px;font:12px/1.5 ui-monospace,Menlo,Consolas,monospace", r.body));
        var close = el("button", "border:0;border-radius:10px;padding:9px 16px;font:600 14px/1 system-ui,-apple-system,'Segoe UI',sans-serif;cursor:pointer;background:#1d1d1f;color:#fff;float:right", "Close");
        close.type = "button"; close.onclick = function () { dlg.close(); }; dlg.appendChild(close);
        document.body.appendChild(dlg); dlg.showModal();
      };
    });
  })();

  // --- A What's new tour step on this page: the Nikxel window opened this meeting to show where
  // Push to dashboard is. Dims the rest, points at the bar, then Next hands the tour back.
  call("coach").then(function (r) {
    var st = r && r.step, target = document.querySelector(".nx-project");
    if (!st) return;
    target = target && target.closest(".client-cta");
    if (!target) return call("coach-done");
    window.__nxCoach = true;
    target.scrollIntoView({ block: "center" });
    var hole = document.createElement("div"), tip = document.createElement("div"), font = "system-ui,-apple-system,'Segoe UI',sans-serif";
    hole.style.cssText = "position:fixed;z-index:98;border-radius:18px;box-shadow:0 0 0 9999px rgba(10,12,16,.55);pointer-events:none";
    tip.style.cssText = "position:fixed;z-index:99;width:min(340px,calc(100vw - 32px));box-sizing:border-box;padding:16px 18px;border-radius:14px;background:#5e5ce6;color:#fff;font:14px/1.45 " + font + ";box-shadow:0 12px 40px rgba(0,0,0,.35)";
    var b = document.createElement("b"), p = document.createElement("p"), row = document.createElement("div"), n = document.createElement("span");
    b.style.cssText = "display:block;font-size:15px;margin-bottom:4px"; b.textContent = st.title;
    p.style.cssText = "margin:0 0 12px"; p.textContent = st.text;
    row.style.cssText = "display:flex;align-items:center;gap:14px"; n.style.cssText = "opacity:.8;font-size:12px;margin-right:auto"; n.textContent = st.n + " of " + st.of;
    row.appendChild(n); tip.append(b, p, row);
    function place() {
      var rc = target.getBoundingClientRect(), pad = 6;
      Object.assign(hole.style, { left: rc.left - pad + "px", top: rc.top - pad + "px", width: rc.width + pad * 2 + "px", height: rc.height + pad * 2 + "px" });
      var below = rc.bottom + 14 + tip.offsetHeight < innerHeight;
      tip.style.left = Math.max(16, Math.min(rc.left, innerWidth - tip.offsetWidth - 16)) + "px";
      tip.style.top = (below ? rc.bottom + 14 : Math.max(16, rc.top - tip.offsetHeight - 14)) + "px";
    }
    function button(label, primary, skip) {
      var x = document.createElement("button"); x.type = "button"; x.textContent = label;
      x.style.cssText = "border:0;cursor:pointer;font:600 13px " + font + ";border-radius:999px;" + (primary ? "padding:7px 16px;background:#fff;color:#3a38b8" : "padding:7px 0;background:none;color:#fff;text-decoration:underline");
      x.onclick = function () {
        hole.remove(); tip.remove(); removeEventListener("resize", place); removeEventListener("scroll", place, true);
        call("coach-done", skip ? { skip: "1" } : {});
      };
      row.appendChild(x);
    }
    if (!st.last) button("Skip", false, true);
    button(st.last ? "Done" : "Next", true, false);
    document.body.append(hole, tip); place(); setTimeout(place, 400);   // after the scroll settles
    addEventListener("resize", place); addEventListener("scroll", place, true);
  });

  // --- Daily page: cross out what stays private, then send the day to the
  // org dashboard. What was crossed out comes back from <day>.sent.json.
  var bar = document.querySelector(".nx-send");
  if (bar) {
    var sendBtn = bar.querySelector("button"), sentMsg = bar.querySelector(".nx-sent");
    var hhmm = function (s) { var d = new Date(s * 1000); return ("0" + d.getHours()).slice(-2) + ":" + ("0" + d.getMinutes()).slice(-2); };
    call("dashboard-state").then(function (r) {
      if (!r || r.error) return;
      bar.hidden = false;
      document.querySelectorAll("[data-id]").forEach(function (el) {
        if ((r.skip || []).indexOf(el.getAttribute("data-id")) >= 0) el.classList.add("x");
      });
      if (r.sentAt) sentMsg.textContent = "Sent " + hhmm(r.sentAt);
    });
    document.addEventListener("click", function (e) {
      if (bar.hidden || e.target.closest("a, input, button")) return;
      var item = e.target.closest("[data-id]"); if (!item) return;
      e.preventDefault();   // a click on a task's text crosses it out rather than ticking it
      item.classList.toggle("x");
    });
    sendBtn.onclick = function () {
      var skip = [].map.call(document.querySelectorAll("[data-id].x"), function (el) { return el.getAttribute("data-id"); });
      sendBtn.disabled = true; sentMsg.textContent = "Sending…";
      call("dashboard", { skip: skip.join(",") }).then(function (r) {
        sendBtn.disabled = false;
        sentMsg.textContent = (r && r.error) || "Sent ✓ " + hhmm(Date.now() / 1000);
      });
    };
  }

  // --- One-click ERP "Assign" on each action item, when the ERP is
  // connected. Creates the task (title + matched assignee + due) and opens it
  // in this browser; the user sets the project and the rest in Odoo.
  call("erp").then(function (r) {
    if (!r || !r.connected) return;
    var mon = { jan:0,feb:1,mar:2,apr:3,may:4,jun:5,jul:6,aug:7,sep:8,oct:9,nov:10,dec:11 };
    function pad(n){ return (n<10?"0":"")+n; }
    function parseDue(t){
      var m=(t||"").match(/(\d{1,2})\s+([A-Za-z]{3})/); if(!m) return "";
      var mo=mon[m[2].toLowerCase()]; if(mo==null) return "";
      var d=new Date(), dt=new Date(d.getFullYear(),mo,parseInt(m[1],10));
      if(dt.getTime()<d.getTime()-30*864e5) dt.setFullYear(d.getFullYear()+1); // roll to next year if clearly past
      return dt.getFullYear()+"-"+pad(dt.getMonth()+1)+"-"+pad(dt.getDate());
    }
    document.querySelectorAll("li.task").forEach(function(li){
      var tEl=li.querySelector(".t"); if(!tEl) return;
      var title=tEl.textContent.trim();
      var whoEl=li.querySelector(".chip.who"), who="";
      if(whoEl){ var c=whoEl.cloneNode(true), av=c.querySelector(".av"); if(av)av.remove(); who=c.textContent.trim(); }
      var dueEl=li.querySelector(".chip.due"), dueText=dueEl?dueEl.textContent.replace(/^Due\s*/,"").trim():"";
      var btn=document.createElement("button"); btn.type="button"; btn.className="nx-assign"; btn.textContent="Assign in ERP";
      btn.onclick=function(e){
        e.preventDefault(); e.stopPropagation();
        if(btn.classList.contains("done")){ if(btn._url) window.open(btn._url,"_blank"); return; }
        if(btn.disabled) return;
        btn.textContent="Creating…"; btn.disabled=true;
        call("assign",{ title:title, who:who, due:parseDue(dueText) }).then(function(r){
          btn.disabled=false;
          if(r && r.url){ btn._url=r.url; btn.classList.add("done"); btn.textContent="Open in ERP ✓"; window.open(r.url,"_blank"); }
          else { btn.textContent="Assign in ERP"; alert((r&&r.error)||"Couldn't create the task in ERP."); }
        });
      };
      (li.querySelector("label")||li).appendChild(btn);
    });
  });
})();</script><!--/nikxel-share-->
"""#
}
