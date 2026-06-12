import Foundation
import Cocoa
import Network

class GoogleCalendarWatcher {
    let stateMachine: StateMachine
    private var timer: Timer?
    private var firedEventIds: Set<String> = []
    private var leadMinutes: Int = 2

    private let credsPath: URL
    private let tokenPath: URL
    private var listener: NWListener?

    var onReminder: ((String) -> Void)?

    private var clientId: String?
    private var clientSecret: String?
    private var accessToken: String?
    private var refreshToken: String?
    private var accessTokenExpiry: Date?

    init(stateMachine: StateMachine) {
        self.stateMachine = stateMachine
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".nikxel", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.credsPath = dir.appendingPathComponent("google_creds.json")
        self.tokenPath = dir.appendingPathComponent("google_token.json")
    }

    func start() {
        guard loadCreds() else {
            DispatchQueue.main.async { [weak self] in self?.showSetupAlert() }
            return
        }
        if loadTokens() {
            DispatchQueue.main.async { [weak self] in self?.scheduleTimer() }
        } else {
            DispatchQueue.main.async { [weak self] in self?.startOAuthFlow() }
        }
    }

    func stop() {
        timer?.invalidate(); timer = nil
        listener?.cancel(); listener = nil
    }

    func reauthenticate() {
        guard loadCreds() else { showSetupAlert(); return }
        startOAuthFlow()
    }

    func setLeadMinutes(_ m: Int) { leadMinutes = max(0, m) }

    // MARK: - Persistence

    private func loadCreds() -> Bool {
        guard let data = try? Data(contentsOf: credsPath) else { return false }
        // Google's downloaded creds JSON wraps everything under "installed" or "web".
        if let outer = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            if let inner = (outer["installed"] as? [String: Any]) ?? (outer["web"] as? [String: Any]),
               let cid = inner["client_id"] as? String, let cs = inner["client_secret"] as? String {
                self.clientId = cid; self.clientSecret = cs; return true
            }
            if let cid = outer["client_id"] as? String, let cs = outer["client_secret"] as? String {
                self.clientId = cid; self.clientSecret = cs; return true
            }
        }
        return false
    }

    private func loadTokens() -> Bool {
        guard let data = try? Data(contentsOf: tokenPath),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let rt = obj["refresh_token"] as? String else { return false }
        self.refreshToken = rt
        self.accessToken = obj["access_token"] as? String
        if let exp = obj["expires_at"] as? Double {
            self.accessTokenExpiry = Date(timeIntervalSince1970: exp)
        }
        return true
    }

    private func saveTokens() {
        var obj: [String: Any] = [:]
        if let rt = refreshToken { obj["refresh_token"] = rt }
        if let at = accessToken { obj["access_token"] = at }
        if let exp = accessTokenExpiry { obj["expires_at"] = exp.timeIntervalSince1970 }
        if let data = try? JSONSerialization.data(withJSONObject: obj, options: .prettyPrinted) {
            try? data.write(to: tokenPath)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tokenPath.path)
        }
    }

    // MARK: - OAuth (Installed App / loopback redirect)

    private func startOAuthFlow() {
        guard let clientId = clientId else { return }
        // Tear down any listener left over from a prior (aborted) attempt — otherwise
        // its newConnectionHandler keeps the OLD `state` UUID and any new auth will
        // be rejected as "state mismatch" → "Authorization failed".
        listener?.cancel()
        listener = nil

        bindLoopbackListenerAsync { [weak self] result in
            guard let self = self else { return }
            guard let (listener, port) = result else {
                DispatchQueue.main.async { self.showAlert("Could not bind a local port for the OAuth callback.") }
                return
            }
            self.continueOAuthFlow(listener: listener, port: port, clientId: clientId)
        }
    }

    private func continueOAuthFlow(listener: NWListener, port: Int, clientId: String) {
        self.listener = listener
        let redirectURI = "http://127.0.0.1:\(port)/callback"
        let state = UUID().uuidString

        listener.newConnectionHandler = { [weak self] conn in
            conn.start(queue: .main)
            conn.receive(minimumIncompleteLength: 1, maximumLength: 16384) { data, _, _, _ in
                defer { conn.cancel() }
                guard let data = data, let req = String(data: data, encoding: .utf8) else { return }
                let code = Self.queryParam(request: req, key: "code")
                let returnedState = Self.queryParam(request: req, key: "state")
                let body: String
                if let code = code, returnedState == state {
                    body = "<html><body style='font-family:-apple-system;text-align:center;padding:60px'><h2>Nikxel: connected ✓</h2><p>You can close this tab.</p></body></html>"
                    self?.exchangeCodeForToken(code: code, redirectURI: redirectURI)
                } else {
                    body = "<html><body style='font-family:-apple-system;text-align:center;padding:60px'><h2>Authorization failed</h2></body></html>"
                }
                let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                conn.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in })
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    self?.listener?.cancel()
                    self?.listener = nil
                }
            }
        }
        // listener is already started by bindLoopbackListenerAsync; safe to set
        // newConnectionHandler after .ready since incoming connections only arrive
        // once the browser hits the redirect URL below.

        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: "https://www.googleapis.com/auth/calendar.readonly"),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
            URLQueryItem(name: "state", value: state)
        ]
        if let url = components.url { NSWorkspace.shared.open(url) }
    }

    private func bindLoopbackListenerAsync(completion: @escaping ((NWListener, Int)?) -> Void) {
        // NWListener init doesn't actually try to bind — bind happens on start(),
        // and failure is reported asynchronously via stateUpdateHandler. So we have
        // to wait for .ready (success) or .failed (try next port).
        let ports = Array(49100..<49200).shuffled()
        func attempt(_ idx: Int) {
            if idx >= ports.count { completion(nil); return }
            let port = ports[idx]
            guard let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else { attempt(idx + 1); return }
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            params.acceptLocalOnly = true
            let listener: NWListener
            do { listener = try NWListener(using: params, on: nwPort) } catch {
                attempt(idx + 1); return
            }
            var settled = false
            listener.stateUpdateHandler = { state in
                if settled { return }
                switch state {
                case .ready:
                    settled = true
                    completion((listener, port))
                case .failed(let err):
                    settled = true
                    print("OAuth bind port \(port) failed: \(err)")
                    listener.cancel()
                    attempt(idx + 1)
                case .cancelled:
                    settled = true
                default:
                    break
                }
            }
            // macOS requires a newConnectionHandler before start() — install a
            // placeholder that drops connections. continueOAuthFlow replaces it
            // with the real handler before opening the browser.
            listener.newConnectionHandler = { conn in conn.cancel() }
            listener.start(queue: .main)
        }
        attempt(0)
    }

    private static func queryParam(request: String, key: String) -> String? {
        guard let firstLine = request.split(separator: "\r\n", maxSplits: 1).first else { return nil }
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        let path = String(parts[1])
        guard let queryPart = path.split(separator: "?", maxSplits: 1).last, queryPart != Substring(path) else { return nil }
        for pair in queryPart.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            if kv.count == 2 && kv[0] == Substring(key) {
                return String(kv[1]).removingPercentEncoding
            }
        }
        return nil
    }

    private func exchangeCodeForToken(code: String, redirectURI: String) {
        guard let clientId = clientId, let clientSecret = clientSecret else { return }
        var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let form = [
            "code": code,
            "client_id": clientId,
            "client_secret": clientSecret,
            "redirect_uri": redirectURI,
            "grant_type": "authorization_code"
        ]
        req.httpBody = Self.formEncode(form).data(using: .utf8)
        URLSession.shared.dataTask(with: req) { [weak self] data, _, err in
            guard let self = self else { return }
            guard let data = data,
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                DispatchQueue.main.async { self.showAlert("Token exchange failed: \(err?.localizedDescription ?? "no response")") }
                return
            }
            if let at = obj["access_token"] as? String {
                self.accessToken = at
                if let expIn = obj["expires_in"] as? Double {
                    self.accessTokenExpiry = Date().addingTimeInterval(expIn - 60)
                }
                if let rt = obj["refresh_token"] as? String { self.refreshToken = rt }
                self.saveTokens()
                DispatchQueue.main.async {
                    self.scheduleTimer()
                    self.showAlert("Google Calendar connected ✓")
                }
            } else {
                let desc = (obj["error_description"] as? String) ?? (obj["error"] as? String) ?? "unknown error"
                DispatchQueue.main.async { self.showAlert("Token exchange failed: \(desc)") }
            }
        }.resume()
    }

    private func refreshIfNeeded(completion: @escaping (Bool) -> Void) {
        if let at = accessToken, !at.isEmpty, let exp = accessTokenExpiry, exp > Date() {
            completion(true); return
        }
        guard let rt = refreshToken, let cid = clientId, let cs = clientSecret else {
            completion(false); return
        }
        var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = Self.formEncode([
            "refresh_token": rt,
            "client_id": cid,
            "client_secret": cs,
            "grant_type": "refresh_token"
        ]).data(using: .utf8)
        URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
            guard let self = self,
                  let data = data,
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let at = obj["access_token"] as? String else {
                completion(false); return
            }
            self.accessToken = at
            if let expIn = obj["expires_in"] as? Double {
                self.accessTokenExpiry = Date().addingTimeInterval(expIn - 60)
            }
            self.saveTokens()
            completion(true)
        }.resume()
    }

    private static func formEncode(_ params: [String: String]) -> String {
        var cs = CharacterSet.urlQueryAllowed
        cs.remove(charactersIn: "+&=")
        return params.map { k, v in
            let ek = k.addingPercentEncoding(withAllowedCharacters: cs) ?? k
            let ev = v.addingPercentEncoding(withAllowedCharacters: cs) ?? v
            return "\(ek)=\(ev)"
        }.joined(separator: "&")
    }

    // MARK: - Polling

    private func scheduleTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.checkUpcoming() }
        timer?.fire()
    }

    private func checkUpcoming() {
        refreshIfNeeded { [weak self] ok in
            guard ok, let at = self?.accessToken else { return }
            self?.fetchEvents(accessToken: at)
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
            // 401 → force refresh next tick
            if let http = resp as? HTTPURLResponse, http.statusCode == 401 {
                self.accessTokenExpiry = Date(timeIntervalSince1970: 0)
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

    private static func parseGCalDate(_ s: String) -> Date? {
        let f1 = ISO8601DateFormatter(); f1.formatOptions = [.withInternetDateTime]
        if let d = f1.date(from: s) { return d }
        let f2 = ISO8601DateFormatter(); f2.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f2.date(from: s) { return d }
        // All-day events: "YYYY-MM-DD"
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"; df.timeZone = TimeZone.current
        return df.date(from: s)
    }

    // MARK: - UI

    private func showSetupAlert() {
        let alert = NSAlert()
        alert.messageText = "Connect Google Calendar"
        alert.informativeText = """
        One-time setup:

        1. Open Google Cloud Console → APIs & Services → Credentials
        2. Create or pick a project, enable the Google Calendar API
        3. OAuth consent screen → External → add yourself as a test user
        4. Credentials → Create OAuth client ID → "Desktop app"
        5. Download the JSON (or copy client_id + client_secret)
        6. Save it to ~/.nikxel/google_creds.json
        7. Menu bar 🐱 → Connect Google Calendar

        The downloaded Google JSON works as-is.
        """
        alert.addButton(withTitle: "Open Google Cloud Console")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "https://console.cloud.google.com/apis/credentials") {
            NSWorkspace.shared.open(url)
        }
    }

    private func showAlert(_ text: String) {
        let alert = NSAlert()
        alert.messageText = "Google Calendar"
        alert.informativeText = text
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
