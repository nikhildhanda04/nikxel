import Foundation

/// Runs all day (independent of meeting state) building a running record of
/// WhatsApp activity — chat previews and call-log entries — so `DayLogger`
/// can fold "what happened on WhatsApp today" (incl. tasks assigned in chats,
/// and any calls) into the end-of-day summary.
///
/// Reuses the same isolated bot-Chrome/CDP bridge as `ChatbotEngine`
/// (`ChromeWhatsApp`), just polled on a slower, always-on cadence. WhatsApp
/// Web exposes no call audio/transcript — only call-log metadata (caller,
/// missed/incoming/outgoing, time). If a WhatsApp call is actually recorded
/// via Nikxel's normal meeting recorder, its transcript/MOM is picked up
/// separately through the regular meetings pipeline.
class WhatsAppActivityLogger {
    static let shared = WhatsAppActivityLogger()

    private var chatTimer: Timer?
    private var callTimer: Timer?
    private let chatInterval: TimeInterval = 120   // 2 min — cheap, no tab switch
    private let callInterval: TimeInterval = 600   // 10 min — switches tabs, so less often

    private let logDir: URL
    private let queue = DispatchQueue(label: "nikxel.whatsapp-activity", qos: .utility)

    // In-memory dedupe so we only append NEW info to the day's log, same
    // delta-logging shape as DayLogger's app-usage sampler.
    private var lastPreview: [String: String] = [:]
    private var seenCallKeys: Set<String> = []

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.logDir = home.appendingPathComponent("Library/Application Support/Nikxel/whatsapp", isDirectory: true)
        try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
    }

    func start() {
        pollChats()
        chatTimer = Timer.scheduledTimer(withTimeInterval: chatInterval, repeats: true) { [weak self] _ in
            self?.pollChats()
        }
        pollCalls()
        callTimer = Timer.scheduledTimer(withTimeInterval: callInterval, repeats: true) { [weak self] _ in
            self?.pollCalls()
        }
    }

    func stop() {
        chatTimer?.invalidate(); chatTimer = nil
        callTimer?.invalidate(); callTimer = nil
    }

    // MARK: - Polling

    private func pollChats() {
        queue.async { [weak self] in
            guard let self = self else { return }
            let chats = ChromeWhatsApp.allChatsPreview()
            guard !chats.isEmpty else { return }
            for chat in chats {
                if self.lastPreview[chat.name] == chat.preview { continue }
                self.lastPreview[chat.name] = chat.preview
                self.appendJSONL(file: "chats", entry: [
                    "t": Date().timeIntervalSince1970,
                    "name": chat.name,
                    "preview": chat.preview
                ])
            }
        }
    }

    private func pollCalls() {
        queue.async { [weak self] in
            guard let self = self else { return }
            let calls = ChromeWhatsApp.callLog()
            // Always restore the Chats tab afterward — ChatbotEngine's unread
            // polling assumes the chat list, not the call log, is on screen.
            defer { ChromeWhatsApp.openChatsTab() }
            for call in calls {
                let key = "\(call.name)|\(call.info)|\(call.timeText)"
                if self.seenCallKeys.contains(key) { continue }
                self.seenCallKeys.insert(key)
                self.appendJSONL(file: "calls", entry: [
                    "t": Date().timeIntervalSince1970,
                    "name": call.name,
                    "info": call.info,
                    "timeText": call.timeText
                ])
            }
        }
    }

    // MARK: - Persistence

    private func appendJSONL(file: String, entry: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: entry, options: []) else { return }
        var line = data
        line.append(0x0A)
        let url = Self.fileURL(logDir: logDir, file: file, for: Date())
        if FileManager.default.fileExists(atPath: url.path) {
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(line)
                try? handle.close()
            }
        } else {
            try? line.write(to: url, options: .atomic)
        }
    }

    private static func fileURL(logDir: URL, file: String, for date: Date) -> URL {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        return logDir.appendingPathComponent("\(file)-\(fmt.string(from: date)).jsonl")
    }

    /// Read back today's (or any day's) raw entries for `DayLogger` to fold
    /// into the EOD summary prompt.
    static func readLog(file: String, for date: Date) -> [[String: Any]] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dir = home.appendingPathComponent("Library/Application Support/Nikxel/whatsapp", isDirectory: true)
        let url = fileURL(logDir: dir, file: file, for: date)
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        var out: [[String: Any]] = []
        for line in content.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            out.append(obj)
        }
        return out
    }
}
