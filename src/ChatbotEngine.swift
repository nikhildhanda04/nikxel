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

func cblog(_ msg: String) {
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
    // Conversation history, per contact. Capped -- in the always-on modes there
    // is no meeting boundary to clear it at, and only the last few turns are
    // ever put in the prompt anyway.
    private var conversationHistory: [String: [(role: String, text: String)]] = [:]
    private let historyCap = 12

    /// Messages seen but not yet answered, keyed the same way as `baselineCounts`.
    /// An entry lives from the moment new unread arrives until either the bot
    /// replies or the user reads the chat themselves.
    private struct Pending {
        var chat: WAUnreadChat
        var newCount: Int
        let since: Date
    }
    private var pending: [String: Pending] = [:]

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
        conversationHistory.removeAll(); pending.removeAll(); setActiveContact(nil)
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
                conversationHistory.removeAll(); pending.removeAll()
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
        let want = MeetingDetector.shared.isInMeeting ? meetingPollInterval : idlePollInterval
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
        guard !cancelled, !pollingInProgress else { return }
        pollingInProgress = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            defer { self?.pollingInProgress = false }
            self?.performCheck()
        }
    }

    // MARK: - Core logic

    private func performCheck() {
        // 1. Get all unread chats via Chrome JS (fast — no AX traversal needed).
        let unreadChats = ChromeWhatsApp.unreadChats()
        cblog("ChatbotEngine: unread=\(unreadChats.count)")
        guard !cancelled else { setActiveContact(nil); return }
        if unreadChats.isEmpty {
            // Nothing unread at all -> nothing is waiting on us any more.
            if !pending.isEmpty { cblog("ChatbotEngine: inbox clear — dropped \(pending.count) pending") }
            pending.removeAll()
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
                cblog("ChatbotEngine: skip '\(chat.name)' — cooldown")
                continue
            }

            // 5. Read only the NEW incoming messages — the ones that arrived
            // while the user wasn't answering. Reading exactly that many
            // incoming bubbles avoids pulling in stale conversation history.
            setActiveContact(chat.name)
            ChromeWhatsApp.clickChat(name: chat.name)
            Thread.sleep(forTimeInterval: 0.6)

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

            let newCount = max(1, p.newCount)
            let messages = ChromeWhatsApp.readMessages(count: newCount)
            cblog("ChatbotEngine: '\(chat.name)' new=\(newCount) msgs=\(messages.count)")

            // 6. Generate reply.
            let history = conversationHistory[key] ?? []
            guard let reply = llm?.reply(for: chat.name, messagePreview: messages.joined(separator: " | "), history: history) else {
                cblog("ChatbotEngine: LLM nil for '\(chat.name)'")
                setActiveContact(nil); continue
            }
            let replyText = reply.text
            guard !cancelled else { break }
            cblog("ChatbotEngine: reply='\(replyText.prefix(80))...'")

            // 7. Verify we're in the right conversation.
            if let header = ChromeWhatsApp.conversationHeader() {
                let a = header.lowercased().trimmingCharacters(in: .whitespaces)
                let b = chat.name.lowercased().trimmingCharacters(in: .whitespaces)
                if a != b && !a.hasPrefix(b) && !b.hasPrefix(a) {
                    cblog("ChatbotEngine: VERIFY FAILED header='\(header)' target='\(chat.name)' — ABORT")
                    setActiveContact(nil); continue
                }
                cblog("ChatbotEngine: verified '\(chat.name)'")
            }

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
            if let task = reply.task {
                GoogleSync.createChatTask(title: task, from: chat.name)
            }

            delivered.append(Delivered(contact: chat.name, text: replyText, task: reply.task))
            lastReplyTime[key] = Date()
            var h = conversationHistory[key] ?? []
            for msg in messages { h.append(("them", msg)) }
            // A draft is not a turn in the conversation -- it hasn't happened
            // yet, and the user may well delete it. Recording it would have the
            // next reply refer back to something never said.
            if !draftOnly { h.append(("bot", replyText)) }
            conversationHistory[key] = Array(h.suffix(historyCap))
            Thread.sleep(forTimeInterval: 0.6)
        }

        if !delivered.isEmpty {
            let batch = delivered
            DispatchQueue.main.async { [weak self] in self?.onRepliesSent?(batch, draftOnly) }
        }
        setActiveContact(nil)
    }

    // MARK: - Helpers

    private func setActiveContact(_ name: String?) {
        guard activeContactName != name else { return }
        activeContactName = name
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .activeTexterChanged, object: nil,
                                            userInfo: ["name": name as Any])
        }
    }
}
