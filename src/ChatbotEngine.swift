import Foundation
import AppKit

extension Notification.Name {
    static let activeTexterChanged = Notification.Name("activeTexterChanged")
}

let logURL: URL = {
    let dir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".nikxel", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent("chatbot.log")
}()

/// Once per launch: a log past 2 MB becomes chatbot.log.1, replacing the
/// last one, so the file stops growing for as long as Nikxel is installed.
private let logRotated: Void = {
    guard let size = (try? FileManager.default.attributesOfItem(atPath: logURL.path))?[.size] as? Int,
          size > 2_000_000 else { return }
    let old = logURL.appendingPathExtension("1")
    try? FileManager.default.removeItem(at: old)
    try? FileManager.default.moveItem(at: logURL, to: old)
}()

func cblog(_ msg: String) {
    _ = logRotated
    let line = "[\(Date())] \(msg)\n"
    if let data = line.data(using: .utf8) {
        if let handle = try? FileHandle(forWritingTo: logURL) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else { try? data.write(to: logURL, options: .atomic) }
    }
    NSLog("%{public}@", msg)
}

// MARK: - Reply gate

/// Whether a given unread chat earns a reply right now. Pulled out of
/// `ChatbotEngine` as a pure function because this is the part with the
/// branches worth checking -- see check_wa_bot.swift.
enum WABotGate {
    enum Decision: Equatable {
        case reply
        /// Eligible, but the unattended timer hasn't run out. Stays pending.
        case wait
        /// Never, for this reason. Dropped.
        case skip(String)
    }

    static func decide(chat: WAUnreadChat,
                       pendingSince: Date,
                       now: Date,
                       inMeeting: Bool,
                       mode: WABotMode,
                       groupReplies: Bool,
                       unattendedSeconds: TimeInterval,
                       blocked: Bool = false,
                       quietHours: Bool = false) -> Decision {
        // The never-reply list beats everything, including a live meeting. The
        // whole value of writing a name down is that it then needs no thought.
        if blocked { return .skip("on your never-reply list") }

        if chat.isGroup {
            guard groupReplies else { return .skip("group chats off") }
            guard chat.mentioned else { return .skip("group, user not tagged") }
        }
        // A meeting is the one state where every mode answers at once: the
        // point of the feature is covering for someone who cannot type. It also
        // overrides quiet hours -- if you're in a meeting at 3am you're awake.
        if inMeeting { return .reply }

        // Checked after the meeting short-circuit and before the mode, so a
        // message that arrives at 2am is held rather than dropped: `.wait`
        // keeps it pending and it goes out once the quiet hours end.
        if quietHours { return .wait }

        switch mode {
        case .meetings:
            return .skip("no meeting")
        case .always:
            return .reply
        case .unattended:
            return now.timeIntervalSince(pendingSince) >= unattendedSeconds
                ? .reply
                : .wait
        }
    }

    /// What the open chat says around the new messages: the earlier turns to put
    /// in the prompt, and whether two bots are talking to each other.
    ///
    /// `thread` is the rendered chat, oldest first. Its trailing run of incoming
    /// bubbles is the new messages being answered, so context is what came
    /// before them -- at most `limit` turns, none older than `idle`, so a chat
    /// that went quiet starts fresh instead of dragging in this morning's topic.
    ///
    /// `botLoop` is two assistants talking to each other: the other side has
    /// called itself an assistant, and this bot has already replied
    /// `loopCap` times since the user last typed. Left alone, two always-on
    /// bots answer each other forever, a paid agent run per message.
    static func threadContext(_ thread: [WAMessage], now: Date,
                              isBot: (String) -> Bool,
                              limit: Int = 5,
                              idle: TimeInterval = 30 * 60,
                              loopCap: Int = 3)
        -> (turns: [(outgoing: Bool, bot: Bool, text: String)], botLoop: Bool) {
        // Continuation rows carry no stamp; they belong to the bubble above.
        var at: Date?
        let stamped = thread.map { m -> (WAMessage, Date?) in
            if let a = m.at { at = a }
            return (m, at)
        }
        var earlier = stamped
        while let last = earlier.last, !last.0.outgoing { earlier.removeLast() }

        let recent = stamped.filter { $0.1.map { now.timeIntervalSince($0) <= idle } ?? false }
        let sinceUser = recent.lastIndex(where: { $0.0.outgoing && !isBot($0.0.text) })
            .map { Array(recent[($0 + 1)...]) } ?? recent
        let botReplies = sinceUser.filter { $0.0.outgoing }.count
        let otherIsBot = sinceUser.contains { !$0.0.outgoing && $0.0.text.localizedCaseInsensitiveContains("assistant") }
        let botLoop = botReplies >= loopCap && otherIsBot

        let turns = earlier
            .filter { $0.1.map { now.timeIntervalSince($0) <= idle } ?? false }
            .suffix(limit)
            .map { (outgoing: $0.0.outgoing, bot: $0.0.outgoing && isBot($0.0.text), text: $0.0.text) }
        return (Array(turns), botLoop)
    }

    /// Whether the open chat has rendered the message the sidebar previews: its
    /// newest incoming bubble matches. An empty preview can't be checked.
    static func showsLatest(_ thread: [WAMessage], preview: String) -> Bool {
        let want = ChatbotEngine.fingerprint(preview)
        guard !want.isEmpty else { return true }
        guard let last = thread.last(where: { !$0.outgoing }) else { return false }
        let got = ChatbotEngine.fingerprint(last.text)
        return !got.isEmpty && (got.hasPrefix(want) || want.hasPrefix(got))
    }

    /// Whether `date` falls inside the quiet window, wrapping past midnight
    /// when `from` is later than `to` (22→8, the normal case). `from == to` is
    /// treated as no quiet hours rather than all of them: a zero-length window
    /// is what you get from a half-filled settings file, and silencing the bot
    /// completely is what the Off switch is for.
    static func isQuietHour(_ date: Date, from: Int, to: Int,
                            calendar: Calendar = .current) -> Bool {
        guard from != to else { return false }
        let h = calendar.component(.hour, from: date)
        return from < to ? (h >= from && h < to)
                         : (h >= from || h < to)
    }
}

// MARK: - ChatbotEngine

class ChatbotEngine {
    static let shared = ChatbotEngine()

    private var timer: Timer?
    private var llm: LLMResponder?
    /// Fast while a meeting is on (a stand-in reply is only useful if it is
    /// prompt); slow the rest of the day, where the bot is either waiting out
    /// an unattended timer measured in minutes or just idling.
    private let meetingPollInterval: TimeInterval = 5
    private let idlePollInterval: TimeInterval = 20
    /// "Reply immediately" promises an answer inside a minute; a 20s poll plus
    /// the agent run ate half of that before the reply was even written.
    private let alwaysPollInterval: TimeInterval = 10
    private var currentInterval: TimeInterval = 0
    // Short cooldown only — the baseline-delta logic in performCheck already
    // prevents replying to the same message twice, so the cooldown only has
    // to throttle pathological bursts (e.g. WhatsApp reordering the sidebar
    // and re-detecting the same chat within one poll cycle).
    private let replyCooldown: TimeInterval = 10

    // Baseline: contact → unread count at meeting start.
    private var baselineCounts: [String: Int] = [:]
    // Cooldown: contact → last reply time.
    private var lastReplyTime: [String: Date] = [:]
    // What the bot has sent, per contact, so the chat thread can tell the
    // bot's bubbles from the user's own. Capped; only recent ones matter.
    private var sentByBot: [String: [String]] = [:]
    private let sentCap = 12

    /// Messages seen but not yet answered, keyed the same way as `baselineCounts`.
    /// An entry lives from the moment new unread arrives until either the bot
    /// replies or the user reads the chat themselves.
    private struct Pending {
        var chat: WAUnreadChat
        var newCount: Int
        let since: Date
        /// Polls this chat was opened but its newest message hadn't rendered.
        var staleReads = 0
    }
    private var pending: [String: Pending] = [:]

    /// Calls agreed in chat, keyed like `pending`: the Meet link goes to the
    /// contact at `at`. Touched from the poll thread and Google callbacks.
    /// ponytail: in memory only -- a call scheduled before a restart loses its
    /// share (the calendar event survives). Persist to disk if that bites.
    private struct ScheduledMeet {
        let contact: String
        var at: Date
        var link: String?
        var eventId: String?
        /// Kept an hour after the link goes out, so "give me 5 more minutes"
        /// is understood as running late, not as a new call needing a new link.
        var sentAt: Date?
    }
    private var meets: [String: ScheduledMeet] = [:]
    private let meetLock = NSLock()
    /// Runs while any call is scheduled, independent of the reply poller, so a
    /// link still goes out after a meeting ends in meetings-only mode.
    private var meetTimer: Timer?

    /// Fired on the main thread after a batch of replies, with one entry per
    /// contact answered and whether they were drafted rather than sent. Wired
    /// to the avatar card in NikxelApp.
    var onRepliesSent: (([Delivered], Bool) -> Void)?

    struct Delivered {
        let contact: String
        let text: String
        /// Task filed to Google Tasks off the back of this message, if any.
        let task: String?
    }

    private(set) var activeContactName: String?
    private var cancelled = false
    private var pollingInProgress = false
    private var lastUnreadLogged = -1
    /// Set while the activity logger has the page on the Calls tab or mid
    /// -reload. The chat list reads as empty then, and an empty list clears
    /// `pending` and the baseline -- so polls skip instead.
    private var held = false

    var hasPending: Bool { !pending.isEmpty }

    /// Run `work` (on the caller's background queue) with polling held off,
    /// once any poll in flight has finished. `work` returning false means the
    /// page didn't come back cleanly: re-baseline so old unread isn't new.
    func withPollingHeld(_ work: () -> Bool) {
        held = true
        defer { held = false }
        let deadline = Date().addingTimeInterval(60)
        while pollingInProgress && Date() < deadline { Thread.sleep(forTimeInterval: 0.2) }
        if !work() { baselineReady = false }
    }
    private var baselineReady = false

    // User toggle (persisted). When false, the bot never auto-replies, even in a meeting.
    var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "nikxel.botEnabled") as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: "nikxel.botEnabled")
            if newValue {
                if shouldRun { cancelled = false; startPolling() }
            } else {
                cancelled = true
                stopPolling()
                setActiveContact(nil)   // clears the "X is texting" bubble immediately
            }
        }
    }

    /// Whether the poller has any reason to be running: the user has the bot
    /// on, and either a meeting is live or the chosen mode covers the rest of
    /// the day too.
    private var shouldRun: Bool {
        isEnabled && (MeetingDetector.shared.isInMeeting
                      || NikxelSettings.waBotMode.runsOutsideMeetings)
    }

    /// Called when the mode or group setting changes from the menu, so the
    /// poller starts, stops or re-paces without waiting for a meeting edge.
    func applyModeChange() {
        if shouldRun {
            cancelled = false
            startPolling()
        } else {
            cancelled = true
            stopPolling()
            setActiveContact(nil)
        }
    }

    // MARK: - Lifecycle

    func start(with momGenerator: MOMGenerator) {
        llm = LLMResponder(momGenerator: momGenerator)
        reset()
        NotificationCenter.default.addObserver(
            self, selector: #selector(meetingStateChanged),
            name: .meetingStateChanged, object: nil
        )
        cblog("ChatbotEngine: started (Chrome JS mode, mode=\(NikxelSettings.waBotMode.rawValue))")
        cancelled = false
        if shouldRun { startPolling() }
    }

    func stop() {
        timer?.invalidate(); timer = nil
        NotificationCenter.default.removeObserver(self)
        reset()
    }

    private func reset() {
        cancelled = true; pollingInProgress = false; baselineReady = false
        baselineCounts.removeAll(); lastReplyTime.removeAll()
        sentByBot.removeAll(); pending.removeAll(); setActiveContact(nil)
    }

    @objc private func meetingStateChanged(_ notification: Notification) {
        let on = MeetingDetector.shared.isInMeeting
        let allDay = NikxelSettings.waBotMode.runsOutsideMeetings
        cblog("ChatbotEngine: meeting \(on ? "STARTED" : "ENDED") (allDay=\(allDay))")
        if on {
            // Meeting-only mode treats each meeting as a fresh session; an
            // all-day mode has been running and keeps its baseline, otherwise
            // every meeting would re-ignore whatever was already unread.
            if !allDay {
                baselineReady = false
                baselineCounts.removeAll(); lastReplyTime.removeAll()
                sentByBot.removeAll(); pending.removeAll()
            }
            cancelled = false
            startPolling()
        } else if allDay {
            startPolling()   // re-paces to the idle interval
        } else {
            cancelled = true; stopPolling(); reset()
        }
    }

    // MARK: - Polling

    private func startPolling() {
        guard isEnabled else { return }
        let want = MeetingDetector.shared.isInMeeting ? meetingPollInterval
            : NikxelSettings.waBotMode == .always ? alwaysPollInterval : idlePollInterval
        if timer != nil && currentInterval == want { return }
        timer?.invalidate()
        currentInterval = want
        cblog("ChatbotEngine: polling every \(want)s")
        timer = Timer.scheduledTimer(withTimeInterval: want, repeats: true) { [weak self] _ in
            self?.checkAndReply()
        }
        checkAndReply()
    }

    private func stopPolling() { timer?.invalidate(); timer = nil; currentInterval = 0 }

    private func checkAndReply() {
        guard !cancelled, !pollingInProgress, !held else { return }
        pollingInProgress = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            defer { self?.pollingInProgress = false }
            self?.performCheck()
        }
    }

    // MARK: - Core logic

    private func performCheck() {
        sendDueMeets()
        // 1. Get all unread chats via Chrome JS (fast — no AX traversal needed).
        let unreadChats = ChromeWhatsApp.unreadChats()
        // Only when it moves: every 10-20s all day was most of the log.
        if unreadChats.count != lastUnreadLogged {
            lastUnreadLogged = unreadChats.count
            cblog("ChatbotEngine: unread=\(unreadChats.count)")
        }
        guard !cancelled else { setActiveContact(nil); return }
        if unreadChats.isEmpty {
            // Nothing unread at all -> nothing is waiting on us any more.
            if !pending.isEmpty { cblog("ChatbotEngine: inbox clear — dropped \(pending.count) pending") }
            pending.removeAll()
            // Same decay as 3a: with nothing unread every baseline is 0, or a
            // chat that was unread at start, then read, stays at its old count
            // and its next message (1 > 1 is false) is never answered.
            baselineCounts.removeAll()
            setActiveContact(nil); return
        }

        // 2. First poll: build baseline. Don't set lastReplyTime — baseline is
        // for "what was already unread before I joined the meeting", not for
        // suppressing real replies. Cooldown applies only after an actual send.
        if !baselineReady {
            for chat in unreadChats {
                let key = chat.name.lowercased().trimmingCharacters(in: .whitespaces)
                baselineCounts[key] = chat.unread
            }
            baselineReady = true
            cblog("ChatbotEngine: baseline=\(baselineCounts.count) contacts")
            setActiveContact(nil)
            return
        }

        // 3a. Decay baseline for contacts that no longer appear in the
        // unread list — the user read them on their phone, so the next
        // message from that contact is "new" relative to a zero baseline.
        // Without this, a contact that had 3 unread at meeting start, was
        // read on phone, then sends 1 new msg, looks like 1 ≤ 3 and the
        // bot stays silent.
        //
        // Leaving the unread list is also exactly what "the user attended to
        // it" looks like, so any pending reply for that chat is dropped here.
        // That is the whole point of `.unattended` mode: answer the phone only
        // after it has rung long enough that nobody else is going to.
        let currentKeys = Set(unreadChats.map {
            $0.name.lowercased().trimmingCharacters(in: .whitespaces)
        })
        for key in Array(baselineCounts.keys) where !currentKeys.contains(key) {
            baselineCounts[key] = 0
        }
        for key in Array(pending.keys) where !currentKeys.contains(key) {
            cblog("ChatbotEngine: drop pending '\(key)' — user read it")
            pending[key] = nil
        }

        // 3b. Fold unread count INCREASES into `pending`. The baseline moves
        // immediately so the same message is never counted twice, but the delta
        // is held until the gate actually lets a reply out — in `.unattended`
        // mode that can be minutes later, or never.
        //
        // `since` is the FIRST unanswered message, not the latest: someone who
        // keeps typing shouldn't keep pushing their own timer back.
        for chat in unreadChats {
            guard !cancelled else { break }
            let key = chat.name.lowercased().trimmingCharacters(in: .whitespaces)
            let baseline = baselineCounts[key] ?? 0
            if chat.unread > baseline {
                let delta = chat.unread - baseline
                baselineCounts[key] = chat.unread
                if var p = pending[key] {
                    p.newCount += delta
                    p.chat = chat
                    pending[key] = p
                } else {
                    pending[key] = Pending(chat: chat, newCount: delta, since: Date())
                }
            } else if pending[key] != nil {
                // Still waiting on this one — refresh the row so a mention
                // badge that only appeared on a later message is seen.
                pending[key]?.chat = chat
            }
        }
        guard !pending.isEmpty else { setActiveContact(nil); return }

        // 3c. Decide, per chat, whether a reply goes out now.
        let now = Date()
        let inMeeting = MeetingDetector.shared.isInMeeting
        let mode = NikxelSettings.waBotMode
        let groupReplies = NikxelSettings.waGroupReplies
        let unattendedSeconds = TimeInterval(NikxelSettings.waUnattendedMinutes * 60)
        let blockList = WAContactLists.names(.neverReply)
        let quiet = NikxelSettings.waQuietHours
            && WABotGate.isQuietHour(now,
                                     from: NikxelSettings.waQuietFrom,
                                     to: NikxelSettings.waQuietTo)
        var due: [Pending] = []
        for (key, p) in pending {
            switch WABotGate.decide(chat: p.chat, pendingSince: p.since, now: now,
                                    inMeeting: inMeeting, mode: mode,
                                    groupReplies: groupReplies,
                                    unattendedSeconds: unattendedSeconds,
                                    blocked: WAContactLists.matches(blockList, contact: p.chat.name),
                                    quietHours: quiet) {
            case .reply:
                due.append(p)
                pending[key] = nil
            case .wait:
                break
            case .skip(let why):
                cblog("ChatbotEngine: skip '\(p.chat.name)' — \(why)")
                pending[key] = nil
            }
        }
        guard !due.isEmpty else { setActiveContact(nil); return }
        let draftOnly = NikxelSettings.waDraftOnly
        cblog("ChatbotEngine: \(draftOnly ? "drafting for" : "replying to") \(due.count) — \(due.map { $0.chat.name })")
        var delivered: [Delivered] = []

        // 4. Process each due chat.
        for p in due {
            guard !cancelled else { break }
            let chat = p.chat
            let key = chat.name.lowercased().trimmingCharacters(in: .whitespaces)

            // Cooldown.
            if let last = lastReplyTime[key], Date().timeIntervalSince(last) < replyCooldown {
                // Back on the pile, not dropped: a second message a moment after
                // the first is a real message, and the baseline is already past it.
                cblog("ChatbotEngine: '\(chat.name)' in cooldown — answering next poll")
                pending[key] = p
                continue
            }

            // 5. Read only the NEW incoming messages — the ones that arrived
            // while the user wasn't answering. Reading exactly that many
            // incoming bubbles avoids pulling in stale conversation history.
            setActiveContact(chat.name)
            ChromeWhatsApp.clickChat(name: chat.name)
            // Wait for the message pane to actually populate rather than
            // guessing at a sleep: it is virtualised, and 0.6s measured zero
            // rows on a real chat, which reads as "nothing to say".
            //
            // A pane that never renders is a transient failure, not an empty
            // chat, so the message goes back on the pending pile to be tried
            // again next poll. Dropping it would lose that message for good:
            // the baseline has already moved past it.
            if !ChromeWhatsApp.waitForMessages() {
                cblog("ChatbotEngine: '\(chat.name)' pane didn't render — retrying next poll")
                pending[key] = p
                setActiveContact(nil); continue
            }

            // 5b. Second opinion on group-ness, now that the chat is open. The
            // sidebar heuristic can miss (a group whose last message happens to
            // carry no sender prefix), and replying into a group the user never
            // opted into is the expensive mistake.
            if !chat.isGroup && ChromeWhatsApp.openChatIsGroup() {
                if !groupReplies || !chat.mentioned {
                    cblog("ChatbotEngine: '\(chat.name)' is a group after all — not replying")
                    setActiveContact(nil); continue
                }
            }

            // 5a. The sidebar shows a message before the open pane renders it.
            // Reading too early answered an older message ("Np") instead of the
            // two questions that had just arrived. Wait for the newest incoming
            // bubble to match the preview; if it never does, try next poll --
            // twice, then answer what's there (a photo's preview never matches).
            var thread = ChromeWhatsApp.readThread()
            let deadline = Date().addingTimeInterval(4)
            while !WABotGate.showsLatest(thread, preview: chat.preview), Date() < deadline {
                Thread.sleep(forTimeInterval: 0.4)
                thread = ChromeWhatsApp.readThread()
            }
            if !WABotGate.showsLatest(thread, preview: chat.preview) && p.staleReads < 2 {
                cblog("ChatbotEngine: '\(chat.name)' newest message not rendered yet — retrying next poll")
                var again = p; again.staleReads += 1
                pending[key] = again
                setActiveContact(nil); continue
            }

            // Everything since the last message from this side is unanswered --
            // the unread badge undercounts when two arrive between polls.
            let unanswered = thread.reversed().prefix { !$0.outgoing }.reversed().map(\.text)
            let messages = Array(unanswered.suffix(max(6, p.newCount)))
            cblog("ChatbotEngine: '\(chat.name)' new=\(p.newCount) msgs=\(messages.count)")

            // Nothing readable -- a sticker, an image, or a sender WhatsApp
            // won't name. Replying anyway handed the model an empty "their
            // latest message" and let it answer something it had never read.
            guard !messages.isEmpty else {
                cblog("ChatbotEngine: skip '\(chat.name)' — nothing readable in the new messages")
                setActiveContact(nil); continue
            }

            // 5c. The chat around those messages: earlier turns for the prompt,
            // and whether this is two bots answering each other.
            let sent = sentByBot[key] ?? []
            let ctx = WABotGate.threadContext(thread, now: Date(), isBot: { text in
                let t = Self.fingerprint(text)
                return text.localizedCaseInsensitiveContains("AI Assistant")
                    || sent.contains { Self.fingerprint($0) == t }
            })
            if ctx.botLoop {
                cblog("ChatbotEngine: skip '\(chat.name)' — bot-to-bot loop, waiting for a human")
                setActiveContact(nil); continue
            }
            let me = NikxelSettings.userName
            let history = ctx.turns.map { t in
                (role: t.bot ? "you (the assistant)" : t.outgoing ? "\(me) personally" : chat.name, text: t.text)
            }

            // 6. Generate reply.
            // Their own meeting link replaces the one we'd send.
            if messages.contains(where: Self.containsMeetingLink) {
                cancelMeet(key: key, why: "they sent their own link")
            }
            meetLock.lock(); let call = meets[key]; meetLock.unlock()
            guard let reply = llm?.reply(for: chat.name, messagePreview: messages.joined(separator: " | "),
                                         history: history, scheduledCall: call?.at,
                                         linkSent: call?.sentAt != nil) else {
                cblog("ChatbotEngine: LLM nil for '\(chat.name)'")
                setActiveContact(nil); continue
            }
            let replyText = reply.text
            guard !cancelled else { break }
            cblog("ChatbotEngine: reply='\(replyText.prefix(80))...'")

            // 7. Verify we're in the right conversation.
            guard chatIsOpen(chat.name) else { setActiveContact(nil); continue }
            cblog("ChatbotEngine: verified '\(chat.name)'")

            // 8. Send -- or, in draft mode, type it and stop.
            let ok = draftOnly ? ChromeWhatsApp.draftMessage(replyText)
                               : ChromeWhatsApp.sendMessage(replyText)
            cblog("ChatbotEngine: \(draftOnly ? "draft" : "send")=\(ok)")
            guard !cancelled else { break }
            Thread.sleep(forTimeInterval: 0.3)
            guard ok else { setActiveContact(nil); continue }

            // 9. A task the contact asked for, if the reply pass found one.
            // Fire-and-forget: it no-ops without a connected Google account and
            // must never hold up the next chat in the batch.
            switch reply.meet {
            case .inMinutes(let n)?:
                scheduleMeet(key: key, contact: chat.name, inMinutes: n)
            case .cancel?:
                cancelMeet(key: key, why: "they called it off")
            default:
                break
            }

            if let task = reply.task {
                GoogleSync.createChatTask(title: task, from: chat.name)
            }

            delivered.append(Delivered(contact: chat.name, text: replyText, task: reply.task))
            lastReplyTime[key] = Date()
            // A draft isn't the bot's message until the user sends it; if they
            // do, it's theirs.
            if !draftOnly { sentByBot[key] = Array(((sentByBot[key] ?? []) + [replyText]).suffix(sentCap)) }
            Thread.sleep(forTimeInterval: 0.6)
        }

        if !delivered.isEmpty {
            let batch = delivered
            DispatchQueue.main.async { [weak self] in self?.onRepliesSent?(batch, draftOnly) }
        }
        setActiveContact(nil)
    }

    // MARK: - Scheduled Meet links

    /// Someone else's meeting link: theirs replaces the one we'd send.
    static func containsMeetingLink(_ s: String) -> Bool {
        s.range(of: #"meet\.google\.com/|meet\.jit\.si/|zoom\.us/(j|my)/|teams\.(microsoft|live)\.com/"#,
                options: [.regularExpression, .caseInsensitive]) != nil
    }

    private func scheduleMeet(key: String, contact: String, inMinutes n: Int) {
        let at = Date().addingTimeInterval(Double(n * 60))
        meetLock.lock()
        // A call whose link already went out is done; a new ask is a new call.
        let existing = meets[key].flatMap { $0.sentAt == nil ? $0 : nil }
        meets[key] = ScheduledMeet(contact: contact, at: at, link: existing?.link, eventId: existing?.eventId)
        meetLock.unlock()
        if let id = existing?.eventId {
            cblog("ChatbotEngine: call with '\(contact)' moved to \(at)")
            GoogleSync.moveChatMeet(eventId: id, to: at)
        } else if existing == nil {
            cblog("ChatbotEngine: call with '\(contact)' set for \(at) — creating Meet")
            GoogleSync.createChatMeet(with: contact, at: at) { [weak self] link, id in
                guard let self = self else { return }
                self.meetLock.lock()
                if link == nil { self.meets[key] = nil } else { self.meets[key]?.link = link; self.meets[key]?.eventId = id }
                // Moved again while the create was in flight: put the event at the latest time.
                let latest = self.meets[key]?.at
                self.meetLock.unlock()
                if let id = id, let latest = latest, latest != at { GoogleSync.moveChatMeet(eventId: id, to: latest) }
            }
        }
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.meetTimer == nil else { return }
            self.meetTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
                guard let self = self, !self.pollingInProgress, !self.held else { return }
                self.pollingInProgress = true
                DispatchQueue.global(qos: .utility).async {
                    defer { self.pollingInProgress = false }
                    self.sendDueMeets()
                }
            }
        }
    }

    private func cancelMeet(key: String, why: String) {
        meetLock.lock(); let m = meets.removeValue(forKey: key); meetLock.unlock()
        guard let m = m, m.sentAt == nil else { return }
        cblog("ChatbotEngine: call with '\(m.contact)' cancelled — \(why)")
        if let id = m.eventId { GoogleSync.deleteChatMeet(eventId: id) }
    }

    /// Sends every link whose time has come. Runs on the poll thread (start of
    /// each poll) and from `meetTimer`, never both at once.
    private func sendDueMeets() {
        meetLock.lock()
        meets = meets.filter { $0.value.sentAt.map { Date().timeIntervalSince($0) < 3600 } ?? true }
        let due = meets.filter { $0.value.sentAt == nil && $0.value.at <= Date() }
        meetLock.unlock()
        for (key, m) in due {
            guard let link = m.link else {
                // Event creation failed or never returned: nothing to send.
                if Date().timeIntervalSince(m.at) > 120 { cancelMeet(key: key, why: "no Meet link was created") }
                continue
            }
            ChromeWhatsApp.clickChat(name: m.contact)
            guard ChromeWhatsApp.waitForMessages(), chatIsOpen(m.contact) else {
                if Date().timeIntervalSince(m.at) > 300 {
                    cblog("ChatbotEngine: gave up sending Meet link to '\(m.contact)'")
                    meetLock.lock(); meets[key] = nil; meetLock.unlock()
                }
                continue
            }
            let text = "Here's the meeting link for the call: \(link)"
            let ok = NikxelSettings.waDraftOnly ? ChromeWhatsApp.draftMessage(text) : ChromeWhatsApp.sendMessage(text)
            cblog("ChatbotEngine: Meet link to '\(m.contact)' \(NikxelSettings.waDraftOnly ? "drafted" : "sent")=\(ok)")
            if ok {
                meetLock.lock(); meets[key]?.sentAt = Date(); meetLock.unlock()
                if !NikxelSettings.waDraftOnly { sentByBot[key] = Array(((sentByBot[key] ?? []) + [text]).suffix(sentCap)) }
            }
        }
        meetLock.lock(); let empty = meets.values.allSatisfy { $0.sentAt != nil }; meetLock.unlock()
        if empty { DispatchQueue.main.async { [weak self] in self?.meetTimer?.invalidate(); self?.meetTimer = nil } }
    }

    /// Whether the open conversation is `name`'s. No header at all passes, as
    /// it always has: it means WhatsApp's markup moved, not a wrong chat.
    private func chatIsOpen(_ name: String) -> Bool {
        guard let header = ChromeWhatsApp.conversationHeader() else { return true }
        let a = header.lowercased().trimmingCharacters(in: .whitespaces)
        let b = name.lowercased().trimmingCharacters(in: .whitespaces)
        // `contains` as well as the prefix tests: WhatsApp qualifies a
        // group's label with a leading word ("group Warrior Tennis"),
        // and that word is localised, so it cannot all be stripped by
        // name. Containment covers whatever the qualifier turns out to
        // be while still catching a genuinely wrong chat.
        if a != b && !a.hasPrefix(b) && !b.hasPrefix(a) && !a.contains(b) {
            cblog("ChatbotEngine: VERIFY FAILED header='\(header)' target='\(name)' — ABORT")
            return false
        }
        return true
    }

    // MARK: - Helpers

    /// Letters and digits only, first 40: what WhatsApp renders back (emoji
    /// as images, trailing time stripped) rarely matches what was sent exactly.
    static func fingerprint(_ s: String) -> String {
        String(s.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
            .prefix(40).map(Character.init))
    }

    private func setActiveContact(_ name: String?) {
        guard activeContactName != name else { return }
        activeContactName = name
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .activeTexterChanged, object: nil,
                                            userInfo: ["name": name as Any])
        }
    }
}
