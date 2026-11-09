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
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.checkUpcoming() }
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
        let windowEnd = now.addingTimeInterval(TimeInterval(leadMinutes * 60 + 60))
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
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
                if secondsUntil <= Double(self.leadMinutes * 60) && secondsUntil > 0 {
                    self.firedEventIds.insert(id)
                    let minutesUntil = max(1, Int(secondsUntil / 60))
                    let when = minutesUntil <= 1 ? "starting now" : "in \(minutesUntil) min"
                    let text = "📅 \(title) — \(when)"
                    DispatchQueue.main.async {
                        self.stateMachine.triggerAlert()
                        self.onReminder?(text)
                    }
                }
            }
            if self.firedEventIds.count > 200 { self.firedEventIds.removeAll() }
        }.resume()
    }

    static func parseGCalDate(_ s: String) -> Date? {
        let f1 = ISO8601DateFormatter(); f1.formatOptions = [.withInternetDateTime]
        if let d = f1.date(from: s) { return d }
        let f2 = ISO8601DateFormatter(); f2.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f2.date(from: s) { return d }
        // All-day events: "YYYY-MM-DD"
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"; df.timeZone = TimeZone.current
        return df.date(from: s)
    }
}
