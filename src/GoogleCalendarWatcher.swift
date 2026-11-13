import Foundation
import Cocoa

/// Polls the primary Google Calendar and nudges the avatar shortly before an
/// event starts.
///
/// All the OAuth plumbing this used to own -- creds, tokens, the loopback
/// listener, refresh -- now lives in GoogleAuth, shared with GoogleSync so both
/// features run off one grant and one token file.
class GoogleCalendarWatcher {
    let stateMachine: StateMachine
    private var timer: Timer?
    private var firedEventIds: Set<String> = []
    private var leadMinutes: Int = 2
    /// Each fetch looks a poll ahead and sets a timer per event, so the alert
    /// still lands on time; this used to be a fetch every 30 seconds.
    private let pollInterval: TimeInterval = 300
    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f
    }()
    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    private static let dayOnly: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = TimeZone.current; return f
    }()

    var onReminder: ((String) -> Void)?

    init(stateMachine: StateMachine) {
        self.stateMachine = stateMachine
    }

    func start() {
        GoogleAuth.shared.onAuthorized = { [weak self] in self?.scheduleTimer() }
        GoogleAuth.shared.start()
    }

    func stop() {
        timer?.invalidate(); timer = nil
        GoogleAuth.shared.stop()
    }

    func reauthenticate() {
        GoogleAuth.shared.onAuthorized = { [weak self] in self?.scheduleTimer() }
        GoogleAuth.shared.reauthenticate()
    }

    func setLeadMinutes(_ m: Int) { leadMinutes = max(0, m) }

    // MARK: - Polling

    private func scheduleTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in self?.checkUpcoming() }
        timer?.fire()
    }

    private func checkUpcoming() {
        GoogleAuth.shared.withAccessToken { [weak self] token in
            guard let token = token else { return }
            self?.fetchEvents(accessToken: token)
        }
    }

    private func fetchEvents(accessToken: String) {
        let now = Date()
        let windowEnd = now.addingTimeInterval(TimeInterval(leadMinutes * 60) + pollInterval + 60)
        let iso = Self.iso
        var components = URLComponents(string: "https://www.googleapis.com/calendar/v3/calendars/primary/events")!
        components.queryItems = [
            URLQueryItem(name: "timeMin", value: iso.string(from: now)),
            URLQueryItem(name: "timeMax", value: iso.string(from: windowEnd)),
            URLQueryItem(name: "singleEvents", value: "true"),
            URLQueryItem(name: "orderBy", value: "startTime"),
            URLQueryItem(name: "maxResults", value: "10")
        ]
        var req = URLRequest(url: components.url!)
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        URLSession.shared.dataTask(with: req) { [weak self] data, resp, _ in
            guard let self = self, let data = data,
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
            // 401 -> force a refresh on the next tick
            if let http = resp as? HTTPURLResponse, http.statusCode == 401 {
                GoogleAuth.shared.invalidateAccessToken()
                return
            }
            guard let items = obj["items"] as? [[String: Any]] else { return }
            for item in items {
                guard let id = item["id"] as? String else { continue }
                if self.firedEventIds.contains(id) { continue }
                let title = (item["summary"] as? String) ?? "Meeting"
                guard let start = item["start"] as? [String: Any] else { continue }
                let startStr = (start["dateTime"] as? String) ?? (start["date"] as? String) ?? ""
                guard let startDate = Self.parseGCalDate(startStr) else { continue }
                let secondsUntil = startDate.timeIntervalSinceNow
                guard secondsUntil > 0 else { continue }
                self.firedEventIds.insert(id)
                // Wall-clock, so a Mac that sleeps through it doesn't alert late.
                let fireIn = max(0, secondsUntil - Double(self.leadMinutes * 60))
                DispatchQueue.main.asyncAfter(wallDeadline: .now() + fireIn) { [weak self] in
                    let left = startDate.timeIntervalSinceNow
                    guard let self = self, left > -60 else { return }
                    let minutesUntil = max(1, Int(left / 60))
                    let when = minutesUntil <= 1 ? "starting now" : "in \(minutesUntil) min"
                    self.stateMachine.triggerAlert()
                    self.onReminder?("📅 \(title) — \(when)")
                }
            }
            if self.firedEventIds.count > 200 { self.firedEventIds.removeAll() }
        }.resume()
    }

    static func parseGCalDate(_ s: String) -> Date? {
        if let d = iso.date(from: s) { return d }
        if let d = isoFractional.date(from: s) { return d }
        // All-day events: "YYYY-MM-DD"
        return dayOnly.date(from: s)
    }
}
