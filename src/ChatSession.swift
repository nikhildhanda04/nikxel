import AVFoundation
import AppKit

/// One conversation with Nikxel: what the avatar's floating chat and the Nikxel
/// window's Chat section both run. It reads the inbox and the project feed once
/// as it starts, WhatsApp again for each question (and opens any chat the
/// question names, WAChatMatch), then answers from those,
/// what Nikxel knows about the user, what's happening right now, and the last
/// two weeks of summaries (ChatContext). Mail commands and "make a task to …"
/// are handled here, never by the model.
final class ChatSession {
    // Held here: transcribe() bails out quietly if its Transcriber is gone.
    private static let transcriber = Transcriber()

    let agent: MOMGenerator
    private(set) var history: [(q: String, a: String)] = []
    private var feed: (feed: [[String: Any]], offline: Bool) = ([], true)
    private var waSnapshot = ""   // the latest read of WhatsApp (unread, recent chats, open thread)
    private var mailSnapshot = "" // the inbox at open time, when Gmail is connected
    private var knownMailIds: Set<String> = []  // ids the chat has shown the model; labels only touch these
    private var lastDraftId: String?            // what "send it" sends
    private let feedReady = DispatchGroup()
    private var recorder: AVAudioRecorder?
    private let voiceURL = URL(fileURLWithPath: NSHomeDirectory() + "/.nikxel/edits/chat-voice.wav")
    private static let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/nikxel")

    init(agent: MOMGenerator) {
        self.agent = agent
        feedReady.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            self.feed = CloudSync.projectFeed(get: CloudSync.getter(timeout: 3))
            self.waSnapshot = ChatSession.waContextBlock() ?? ""
            if Gmail.isReady {
                let (unread, recent) = Gmail.inbox()
                self.mailSnapshot = MailIntent.contextBlock(unread: unread, recent: recent)
                self.knownMailIds = Set((unread + recent).map(\.id))
            }
            self.feedReady.leave()
        }
    }

    /// What this chat can see, for the window's context panel: [{name, detail, on}].
    /// Waits for the start-up reads, so call it off the main thread.
    func sources() -> [[String: Any]] {
        feedReady.wait()
        let today = Date(), local = ChatContext.localBlocks(root: Self.root, today: today)
        func count(_ kind: String, _ one: String) -> String {
            let n = local.filter { $0.kind == kind }.count
            return n == 0 ? "None in the last 14 days" : "\(n) \(one)\(n == 1 ? "" : "s") from the last 14 days"
        }
        let about = NikxelSettings.userContext.trimmingCharacters(in: .whitespacesAndNewlines)
        let projects = ChatContext.projectBlocks(feed.feed)
        return [
            ["name": "About you", "detail": about.isEmpty ? "Nothing yet. Add it under You." : String(about.prefix(140)), "on": !about.isEmpty],
            ["name": "Right now", "detail": "The app you're in and what you've done today.", "on": DayLogger.current != nil],
            ["name": "Meetings", "detail": count("meeting", "set of minutes"), "on": local.contains { $0.kind == "meeting" }],
            ["name": "Days", "detail": count("daily", "day summary").replacingOccurrences(of: "summarys", with: "summaries"), "on": local.contains { $0.kind == "daily" }],
            ["name": "Notes", "detail": count("note", "note"), "on": local.contains { $0.kind == "note" }],
            ["name": "Projects", "detail": feed.offline ? "Team dashboard not reachable." : "\(Set(projects.map(\.name)).count) projects on your team dashboard.", "on": !feed.offline && !projects.isEmpty],
            ["name": "WhatsApp", "detail": waSnapshot.isEmpty ? "Not open or not logged in." : "Unread, recent chats and the open thread.", "on": !waSnapshot.isEmpty],
            ["name": "Gmail", "detail": mailSnapshot.isEmpty ? (GoogleAuth.shared.isAuthorized ? "Reconnect Google to give me your mail." : "Connect Google to search, draft and tidy mail.") : "Your inbox: search, draft, label, send.", "on": !mailSnapshot.isEmpty],
            ["name": "Forklyft ERP", "detail": ERP.isConnected ? "Say “make a task to …” to create one." : "Not connected.", "on": ERP.isConnected],
        ]
    }

    /// Answers `text`; `done` gets {text, offline, error} on the main thread.
    /// `attach` goes into the context only (an automation's meeting summary),
    /// so what it says can't be taken as a mail or ERP command.
    func send(_ text: String, attach: String = "", done: @escaping ([String: Any]) -> Void) {
        let history = self.history, agent = self.agent, today = Date()
        // "open my latest meeting summary": opened here, never left to the model, which can only answer in words.
        let library = SummaryLibrary.scan()
        if attach.isEmpty, let i = ChatContext.openTarget(text, entries: library.map { (kind: $0.kind, title: $0.title) }) {
            let e = library[i]
            // Always the Nikxel window's reader, whatever "open summaries in" says; a .md-only one has no page to show.
            DispatchQueue.main.async {
                if DashboardWindowController.canRead(e.file) { DashboardWindowController.open(summary: e.file) } else { NSWorkspace.shared.openFile(e.file) }
            }
            let shelf = ["meetings": "Meetings", "daily": "Days", "weekly": "Weeks", "notes": "Notes"][e.kind] ?? "Library"
            let reply = "Opened “\(e.title)” in the Nikxel window. You'll find it any time under Library → \(shelf). It's saved only on this computer."
            self.history.append((q: text, a: reply))
            return done(["text": reply, "offline": false, "error": false])
        }
        DispatchQueue.global(qos: .userInitiated).async {
            self.feedReady.wait()
            let (feed, offline) = self.feed
            // WhatsApp as it is now, not as it was when the chat opened, plus
            // any chat the question names, opened and read in full.
            if ChromeBot.isPortOpen() { self.waSnapshot = ChatSession.waContextBlock() ?? "" }
            let named = self.waNamedThreads(text) ?? ""
            func finish(_ reply: String, answered: Bool) {
                DispatchQueue.main.async {
                    if answered { self.history.append((q: text, a: reply)) }
                    done(["text": reply, "offline": offline, "error": !answered])
                }
            }
            // What Nikxel has learned about the user (names, projects, people) goes first.
            // What Nikxel is doing right now and has done today (apps, code, agent asks),
            // then the WhatsApp read, then the written summaries/notes/projects.
            let live = (DayLogger.current?.liveContext(inMeeting: MeetingDetector.shared.isInMeeting)).map { "### right now\n\($0)" } ?? ""
            // Live connection state, so "is my Gmail connected?" isn't answered from old notes.
            let g = GoogleAuth.shared, yn = { (b: Bool) in b ? "connected" : "not connected" }
            let status = """
                ### connected right now (live; trust this over anything in older notes)
                Google: \(yn(g.isAuthorized)); Gmail: \(yn(g.isAuthorized && g.hasScope("https://www.googleapis.com/auth/gmail.modify"))); \
                Calendar: \(yn(g.isAuthorized && g.hasScope("https://www.googleapis.com/auth/calendar.readonly"))); \
                WhatsApp: \(yn(NikxelSettings.whatsappConnected)); WhatsApp auto-reply: \(ChatbotEngine.shared.isEnabled ? "on" : "off"); \
                Slack: \(yn(Slack.isConnected)); ERP: \(yn(ERP.isConnected)); Organization: \(yn(CloudSync.token != nil))
                """
            var context = [NikxelSettings.userContextBlock, attach, live, status, named, self.waSnapshot, self.mailSnapshot,
                           ChatContext.build(ChatContext.localBlocks(root: Self.root, today: today) + ChatContext.projectBlocks(feed),
                                             cap: ChatContext.cap)].filter { !$0.isEmpty }.joined(separator: "\n\n")
            // Mail: "send it", drafts and labels answer here; a search adds to the context.
            switch self.handleMail(text: text, context: context, history: history, today: today) {
            case .reply(let reply): return finish(reply, answered: true)
            case .context(let more): context += "\n\n" + more
            case .none: break
            }
            // "make a task to …" creates one in ERP, drafted from the same
            // meeting/WhatsApp/project context, then opens it to review.
            if ERP.looksLikeTaskRequest(text) {
                return finish(ChatSession.makeERPTask(request: text, context: context, today: today, agent: agent), answered: true)
            }
            do {
                let a = try agent.runPrompt(ChatContext.prompt(context: context, history: history, question: text, today: today),
                                            kind: "chat", claudeModel: "haiku", timeout: 30)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                cblog("ChatSession: \(context.count) chars of context, answered")
                finish(a, answered: true)
            } catch MOMGenerator.MOMError.agentNotFound {
                finish("Connect Claude in Settings to use chat.", answered: false)
            } catch {
                cblog("ChatSession: \(context.count) chars of context, failed")
                finish("⚠︎ \(error)", answered: false)
            }
        }
    }

    /// Tap once to listen, again to stop and transcribe. `done` gets "recording",
    /// "busy" (the meeting recorder has the mic), "" (no mic), or what was heard.
    func mic(meeting: Bool, done: @escaping (String) -> Void) {
        if let r = recorder {
            r.stop(); recorder = nil
            ChatSession.transcriber.transcribe(audioURL: voiceURL, outputFormat: .txt) { result in
                let heard = (try? result.get()).flatMap { try? String(contentsOf: $0, encoding: .utf8) }?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                DispatchQueue.main.async { done(heard) }
            }
            return
        }
        if meeting { return done("busy") }
        try? FileManager.default.createDirectory(at: voiceURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16000,
                                       AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16]
        if let r = try? AVAudioRecorder(url: voiceURL, settings: settings), r.record() {
            recorder = r; done("recording")
        } else {
            done("")
        }
    }

    func stopMic() { recorder?.stop(); recorder = nil }

    /// Draft an ERP task from the chat request plus context, create it, and open
    /// the record to review — the chat-side twin of the summary's Assign button.
    /// Runs on the send background queue, so the network calls are off main.
    private static func makeERPTask(request: String, context: String, today: Date, agent: MOMGenerator) -> String {
        guard ERP.isConnected else { return "Connect Forklyft ERP in Nikxel first, then ask again." }
        guard ERP.hasLiveSession() else {
            return "Your ERP session has ended — reconnect Forklyft ERP from the Nikxel menu, then try again."
        }
        let draftReply: String   // context already carries the live activity + WhatsApp read
        do {
            draftReply = try agent.runPrompt(ERP.taskDraftPrompt(request: request, context: context, today: today),
                                             kind: "erp-task", claudeModel: "haiku", timeout: 30)
        } catch MOMGenerator.MOMError.agentNotFound {
            return "Connect Claude in Settings to use chat."
        } catch {
            return "⚠︎ \(error)"
        }
        guard let draft = ERP.parseTaskDraft(draftReply) else {
            return "I couldn't turn that into a task. Try naming what to do, e.g. “make a task to send Piyush the invoice by Friday”."
        }
        let r = ERP.createTask(draft: draft)
        guard let url = r.url else { return r.error ?? "ERP didn't create the task." }
        if let u = URL(string: url) { DispatchQueue.main.async { NSWorkspace.shared.open(u) } }
        var line = "Created “\(draft.title)” in ERP"
        if let a = draft.assignee { line += " · for \(a)" }
        if let p = draft.project { line += " · \(p)" }
        if let d = draft.due { line += " · due \(d)" }
        return line + ". Opening it so you can review and edit."
    }

    private enum MailOutcome { case none, reply(String), context(String) }

    /// Off the main thread. Sending is decided here, never by the model: only "send it"
    /// for the draft this chat made. Everything else mail-like goes through the router.
    private func handleMail(text: String, context: String, history: [(q: String, a: String)], today: Date) -> MailOutcome {
        if MailIntent.isSendCommand(text) {
            guard let d = lastDraftId else { return .reply("There's no draft from this chat to send.") }
            guard Gmail.sendDraft(d) else { return .reply("Gmail didn't send it. The draft is still in your Drafts.") }
            lastDraftId = nil
            return .reply("Sent.")
        }
        guard MailIntent.looksLikeMail(text), GoogleAuth.shared.isAuthorized else { return .none }
        guard Gmail.isReady else { return .reply("Reconnect Google from the Nikxel menu to give me your mail.") }
        let routed: String
        do {
            routed = try agent.runPrompt(MailIntent.routerPrompt(request: text, context: context, history: history, today: today),
                                         kind: "mail", claudeModel: "haiku", timeout: 30)
        } catch { return .none }
        switch MailIntent.parseAction(routed) {
        case .answer:
            return .none
        case .search(let q):
            let found = Gmail.search(q)
            knownMailIds.formUnion(found.map(\.id))
            return .context(MailIntent.searchBlock(query: q, found))
        case .draft(let d):
            let original = d.replyTo.flatMap { knownMailIds.contains($0) ? Gmail.message($0) : nil }
            var draft = d
            if let o = original {
                if draft.to.isEmpty { draft.to = o.from }
                if draft.subject.isEmpty { draft.subject = o.subject.lowercased().hasPrefix("re:") ? o.subject : "Re: \(o.subject)" }
            }
            guard !draft.to.isEmpty else { return .reply("Who should it go to? Give me a name from your mail or an address.") }
            guard let made = Gmail.createDraft(draft, replyTo: original) else { return .reply("Gmail didn't save the draft.") }
            lastDraftId = made.draftId
            if let u = URL(string: "https://mail.google.com/mail/u/0/#drafts?compose=\(made.messageId)") {
                DispatchQueue.main.async { NSWorkspace.shared.open(u) }
            }
            return .reply("Draft to \(draft.to) — “\(draft.subject)”. Opened in Gmail; say “send it” to send.")
        case .label(let ids, let op):
            let known = ids.filter(knownMailIds.contains)
            guard !known.isEmpty else { return .reply("I couldn't tell which emails you meant.") }
            guard Gmail.modify(known, op) else { return .reply("Gmail didn't make that change.") }
            let verb = switch op { case .archive: "Archived"; case .read: "Marked read:"; case .unread: "Marked unread:"; case .star: "Starred" }
            return .reply("\(verb) \(known.count) email\(known.count == 1 ? "" : "s").")
        }
    }

    /// A read of WhatsApp for the chat: who's waiting (unread), the recent chats,
    /// and the thread on screen in full — best-effort, no chat switching, only
    /// when the WA browser is up and logged in. nil when there's nothing.
    private static func waContextBlock() -> String? {
        guard ChromeBot.isPortOpen(), ChromeWhatsApp.isLoggedIn() else { return nil }
        var parts: [String] = []
        let unread = ChromeWhatsApp.unreadChats()
        if !unread.isEmpty {
            parts.append("Unread (who's waiting on you):\n" + unread.prefix(15).map {
                "- \($0.name) (\($0.unread)): \($0.preview.prefix(140))" }.joined(separator: "\n"))
        }
        let recent = ChromeWhatsApp.allChatsPreview(limit: 25)
        if !recent.isEmpty {
            parts.append("Recent chats (newest first):\n" + recent.map {
                "- \($0.name): \($0.preview.prefix(140))" }.joined(separator: "\n"))
        }
        // readThread (not readMessages) keeps direction, so each line is labelled
        // by who sent it — otherwise the chat can't tell your words from theirs.
        let thread = ChromeWhatsApp.readThread()
        if !thread.isEmpty {
            let who = ChromeWhatsApp.conversationHeader() ?? "them"
            let lines = thread.suffix(14).map { "\($0.outgoing ? "You" : $0.sender.isEmpty ? who : $0.sender): \($0.text)" }
            parts.append("Open thread with \(who) (each line is labelled with who sent it):\n" + lines.joined(separator: "\n"))
        }
        guard !parts.isEmpty else { return nil }
        return "### whatsapp\n" + parts.joined(separator: "\n\n")
    }

    /// The chats a question names, opened and read now: "what did Piyush say
    /// in the Nikxel group" reads the chats whose names share a word with it.
    /// Opening a chat marks it read in WhatsApp, as it would on the phone.
    /// Afterwards the chat that was open before is opened again.
    /// The chats the last question read: "and yesterday?" reads them again.
    private var lastWANames: [String] = []

    private func waNamedThreads(_ question: String) -> String? {
        guard ChromeBot.isPortOpen(), ChromeWhatsApp.isLoggedIn() else { return nil }
        let day = WAChatMatch.day(in: question)
        var names = WAChatMatch.named(in: question, chats: ChromeWhatsApp.allChatsPreview(limit: 60).map(\.name))
        if names.isEmpty, day != nil { names = lastWANames }
        guard !names.isEmpty else { return nil }
        lastWANames = names
        let when = DateFormatter()
        when.dateFormat = "d MMM h:mm a"
        var parts: [String] = []
        ChatbotEngine.shared.withPollingHeld {
            let back = ChromeWhatsApp.conversationHeader()
            for name in names {
                guard ChromeWhatsApp.clickChat(name: name), ChromeWhatsApp.waitForMessages() else { continue }
                // A day asked about: scroll back to it and read that day; else the latest 40.
                var thread = day.map(ChromeWhatsApp.readBack) ?? ChromeWhatsApp.readThread()
                if let day, let end = Calendar.current.date(byAdding: .day, value: 1, to: day) {
                    // Bubbles in a run carry no stamp: they take the one above.
                    var last: Date?
                    thread = thread.map { m in last = m.at ?? last; return WAMessage(outgoing: m.outgoing, at: last, text: m.text, sender: m.sender) }
                        .filter { ($0.at ?? .distantPast) >= day && ($0.at ?? .distantPast) < end }
                } else {
                    thread = Array(thread.suffix(40))
                }
                guard !thread.isEmpty else { continue }
                parts.append("\(name), read just now (each line: when, who, what):\n" + thread.suffix(200).map {
                    "\($0.at.map { when.string(from: $0) + " " } ?? "")\($0.outgoing ? "You" : $0.sender.isEmpty ? name : $0.sender): \($0.text.prefix(500))"
                }.joined(separator: "\n"))
            }
            if let back, !names.contains(back) { _ = ChromeWhatsApp.clickChat(name: back) }
            return true
        }
        cblog("ChatSession: read \(parts.count) of \(names.count) WhatsApp chats the question named\(day.map { " (back to \($0))" } ?? "")")
        return parts.isEmpty ? nil : "### whatsapp chats you asked about\n" + parts.joined(separator: "\n\n")
    }
}
