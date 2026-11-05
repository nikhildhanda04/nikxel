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

// MARK: - ChatbotEngine

class ChatbotEngine {
    static let shared = ChatbotEngine()

    private var timer: Timer?
    private var llm: LLMResponder?
    private let pollInterval: TimeInterval = 5
    // Short cooldown only — the baseline-delta logic in performCheck already
    // prevents replying to the same message twice, so the cooldown only has
    // to throttle pathological bursts (e.g. WhatsApp reordering the sidebar
    // and re-detecting the same chat within one poll cycle).
    private let replyCooldown: TimeInterval = 10

    // Baseline: contact → unread count at meeting start.
    private var baselineCounts: [String: Int] = [:]
    // Cooldown: contact → last reply time.
    private var lastReplyTime: [String: Date] = [:]
    // Conversation history (per-contact, per-meeting).
    private var conversationHistory: [String: [(role: String, text: String)]] = [:]

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
                if MeetingDetector.shared.isInMeeting { cancelled = false; startPolling() }
            } else {
                cancelled = true
                stopPolling()
                setActiveContact(nil)   // clears the "X is texting" bubble immediately
            }
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
        cblog("ChatbotEngine: started (Chrome JS mode)")
        if MeetingDetector.shared.isInMeeting { startPolling() }
    }

    func stop() {
        timer?.invalidate(); timer = nil
        NotificationCenter.default.removeObserver(self)
        reset()
    }

    private func reset() {
        cancelled = true; pollingInProgress = false; baselineReady = false
        baselineCounts.removeAll(); lastReplyTime.removeAll()
        conversationHistory.removeAll(); setActiveContact(nil)
    }

    @objc private func meetingStateChanged(_ notification: Notification) {
        let on = MeetingDetector.shared.isInMeeting
        cblog("ChatbotEngine: meeting \(on ? "STARTED" : "ENDED")")
        if on {
            cancelled = false; baselineReady = false
            baselineCounts.removeAll(); lastReplyTime.removeAll()
            conversationHistory.removeAll()
            startPolling()
        } else {
            cancelled = true; stopPolling(); reset()
        }
    }

    // MARK: - Polling

    private func startPolling() {
        guard timer == nil else { return }
        guard isEnabled else { return }
        cblog("ChatbotEngine: polling every \(pollInterval)s")
        timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            self?.checkAndReply()
        }
        checkAndReply()
    }

    private func stopPolling() { timer?.invalidate(); timer = nil }

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
        guard !unreadChats.isEmpty, !cancelled else { setActiveContact(nil); return }

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
        let currentKeys = Set(unreadChats.map {
            $0.name.lowercased().trimmingCharacters(in: .whitespaces)
        })
        for key in Array(baselineCounts.keys) where !currentKeys.contains(key) {
            baselineCounts[key] = 0
        }

        // 3b. Only act on unread count INCREASES. Capture the delta now so
        // step 5 can read exactly that many incoming messages, even though
        // we update the baseline up-front (to avoid re-triggering on the
        // next poll if reply send fails).
        var newChats: [WAUnreadChat] = []
        var deltas: [String: Int] = [:]
        for chat in unreadChats {
            guard !cancelled else { break }
            let key = chat.name.lowercased().trimmingCharacters(in: .whitespaces)
            let baseline = baselineCounts[key] ?? 0
            if chat.unread > baseline {
                newChats.append(chat)
                deltas[key] = chat.unread - baseline
                baselineCounts[key] = chat.unread
            }
        }
        guard !newChats.isEmpty else { setActiveContact(nil); return }
        cblog("ChatbotEngine: newUnreads=\(newChats.count) — \(newChats.map(\.name))")

        // 4. Process each new unread.
        for chat in newChats {
            guard !cancelled else { break }
            let key = chat.name.lowercased().trimmingCharacters(in: .whitespaces)

            // Cooldown (120 s).
            if let last = lastReplyTime[key], Date().timeIntervalSince(last) < replyCooldown {
                cblog("ChatbotEngine: skip '\(chat.name)' — cooldown")
                continue
            }

            // 5. Read only the NEW incoming messages — the ones that arrived
            // during the meeting. `chat.unread` is WhatsApp's own unread
            // counter; reading exactly that many incoming bubbles avoids
            // pulling in stale conversation history.
            setActiveContact(chat.name)
            ChromeWhatsApp.clickChat(name: chat.name)
            Thread.sleep(forTimeInterval: 0.6)
            let newCount = max(1, deltas[key] ?? 1)
            let messages = ChromeWhatsApp.readMessages(count: newCount)
            cblog("ChatbotEngine: '\(chat.name)' new=\(newCount) msgs=\(messages.count)")

            // 6. Generate reply.
            let history = conversationHistory[key] ?? []
            guard let replyText = llm?.reply(for: chat.name, messagePreview: messages.joined(separator: " | "), history: history) else {
                cblog("ChatbotEngine: LLM nil for '\(chat.name)'")
                setActiveContact(nil); continue
            }
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

            // 8. Send.
            let sent = ChromeWhatsApp.sendMessage(replyText)
            cblog("ChatbotEngine: send=\(sent)")
            guard !cancelled else { break }
            Thread.sleep(forTimeInterval: 0.3)

            lastReplyTime[key] = Date()
            if conversationHistory[key] == nil { conversationHistory[key] = [] }
            for msg in messages { conversationHistory[key]?.append(("them", msg)) }
            conversationHistory[key]?.append(("bot", replyText))
            Thread.sleep(forTimeInterval: 0.6)
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
