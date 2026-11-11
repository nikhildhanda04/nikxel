import Foundation
import Cocoa
import Network

/// Google OAuth, shared by everything in Nikxel that talks to Google: the
/// calendar watcher that reads upcoming events, and GoogleSync, which writes
/// tasks and follow-up meetings out of a finished MOM.
///
/// One shared instance because there is exactly one ~/.nikxel/google_token.json.
/// Two independent copies would each refresh the access token and clobber the
/// other's, and a second OAuth flow would silently drop the first one's scopes.
///
/// Lifted wholesale out of GoogleCalendarWatcher, which owned all of this when
/// reading the calendar was the only thing Nikxel did with a Google account.
final class GoogleAuth {
    static let shared = GoogleAuth()

    /// Everything Nikxel ever asks for, requested together on one consent
    /// screen. Asking per-feature would mean a second browser round-trip the
    /// first time a summary happened to produce a task.
    static let scopes = [
        "https://www.googleapis.com/auth/calendar.readonly",
        "https://www.googleapis.com/auth/calendar.events",
        "https://www.googleapis.com/auth/tasks",
    ]

    private let credsPath: URL
    private let tokenPath: URL
    private var listener: NWListener?

    private var clientId: String?
    private var clientSecret: String?
    private var accessToken: String?
    private var refreshToken: String?
    private var accessTokenExpiry: Date?
    /// Scopes the stored refresh token was actually granted. Empty for tokens
    /// written by a build that predates write access -- those only ever had
    /// calendar.readonly, so a write has to send the user back through consent.
    private var grantedScopes: Set<String> = []

    /// Fired after a successful authorization, so the calendar watcher can
    /// start polling without GoogleAuth knowing it exists.
    var onAuthorized: (() -> Void)?

    private init() {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".nikxel", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.credsPath = dir.appendingPathComponent("google_creds.json")
        self.tokenPath = dir.appendingPathComponent("google_token.json")
    }

    // MARK: - State

    var hasCreds: Bool { loadCreds() }

    /// True once the user has authorized at least once.
    var isAuthorized: Bool {
        if refreshToken != nil { return true }
        return loadTokens()
    }

    /// Whether the stored grant covers `scope`. Writes check this before
    /// trying, so the user gets "reconnect your Google account" instead of a
    /// bare 403 from the API.
    func hasScope(_ scope: String) -> Bool {
        _ = loadTokens()
        return grantedScopes.contains(scope)
    }

    /// Runs `body` with a valid access token, refreshing first if the current
    /// one has expired. Hands back nil when there is nothing to refresh from.
    func withAccessToken(_ body: @escaping (String?) -> Void) {
        if let at = accessToken, !at.isEmpty, let exp = accessTokenExpiry, exp > Date() {
            body(at); return
        }
        guard loadCreds() else { body(nil); return }
        guard loadTokens(), let rt = refreshToken,
              let cid = clientId, let cs = clientSecret else { body(nil); return }

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
                body(nil); return
            }
            self.accessToken = at
            if let expIn = obj["expires_in"] as? Double {
                self.accessTokenExpiry = Date().addingTimeInterval(expIn - 60)
            }
            // A refresh response repeats the granted scopes; keep them in sync
            // in case the user narrowed the grant from their Google account.
            if let s = obj["scope"] as? String {
                self.grantedScopes = Set(s.split(separator: " ").map(String.init))
            }
            self.saveTokens()
            body(at)
        }.resume()
    }

    /// Forces the next `withAccessToken` to refresh -- call after a 401.
    func invalidateAccessToken() { accessTokenExpiry = Date(timeIntervalSince1970: 0) }

    // MARK: - Entry points

    /// Resume an existing connection on launch. Google is optional, so this
    /// never nags or opens a sign-in -- connecting is the menu's "Connect
    /// Google Account…" (`reauthenticate`).
    func start() {
        guard loadCreds(), loadTokens() else { return }
        DispatchQueue.main.async { [weak self] in self?.onAuthorized?() }
    }

    /// Re-run consent from scratch -- the menu's "Connect Google Account", and
    /// the recovery path when a stored grant is missing a scope.
    func reauthenticate() {
        guard loadCreds() else { showSetupAlert(); return }
        startOAuthFlow()
    }

    func stop() {
        listener?.cancel(); listener = nil
    }

    // MARK: - Persistence

    @discardableResult
    private func loadCreds() -> Bool {
        if clientId != nil && clientSecret != nil { return true }
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

    @discardableResult
    private func loadTokens() -> Bool {
        if refreshToken != nil { return true }
        guard let data = try? Data(contentsOf: tokenPath),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let rt = obj["refresh_token"] as? String else { return false }
        self.refreshToken = rt
        self.accessToken = obj["access_token"] as? String
        if let exp = obj["expires_at"] as? Double {
            self.accessTokenExpiry = Date(timeIntervalSince1970: exp)
        }
        if let s = obj["scope"] as? String {
            self.grantedScopes = Set(s.split(separator: " ").map(String.init))
        }
        return true
    }

    private func saveTokens() {
        var obj: [String: Any] = [:]
        if let rt = refreshToken { obj["refresh_token"] = rt }
        if let at = accessToken { obj["access_token"] = at }
        if let exp = accessTokenExpiry { obj["expires_at"] = exp.timeIntervalSince1970 }
        if !grantedScopes.isEmpty { obj["scope"] = grantedScopes.sorted().joined(separator: " ") }
        if let data = try? JSONSerialization.data(withJSONObject: obj, options: .prettyPrinted) {
            try? data.write(to: tokenPath)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tokenPath.path)
        }
    }

    // MARK: - OAuth (Installed App / loopback redirect)

    private func startOAuthFlow() {
        guard let clientId = clientId else { return }
        // Tear down any listener left over from a prior (aborted) attempt --
        // its newConnectionHandler keeps the OLD `state` UUID and any new auth
        // would be rejected as a state mismatch -> "Authorization failed".
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
                    body = "<html><body style='font-family:-apple-system;text-align:center;padding:60px'><h2>Nikxel: connected &#10003;</h2><p>You can close this tab.</p></body></html>"
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

        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: Self.scopes.joined(separator: " ")),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
            URLQueryItem(name: "state", value: state)
        ]
        if let url = components.url { NSWorkspace.shared.open(url) }
    }

    private func bindLoopbackListenerAsync(completion: @escaping ((NWListener, Int)?) -> Void) {
        // NWListener init doesn't actually try to bind -- bind happens on start(),
        // and failure is reported asynchronously via stateUpdateHandler. So we
        // have to wait for .ready (success) or .failed (try the next port).
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
                    Diag.log("GoogleAuth", "OAuth bind port \(port) failed: \(err)")
                    listener.cancel()
                    attempt(idx + 1)
                case .cancelled:
                    settled = true
                default:
                    break
                }
            }
            // macOS requires a newConnectionHandler before start() -- install a
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
                if let s = obj["scope"] as? String {
                    self.grantedScopes = Set(s.split(separator: " ").map(String.init))
                }
                self.saveTokens()
                let missing = Self.scopes.filter { !self.grantedScopes.contains($0) }
                DispatchQueue.main.async {
                    self.onAuthorized?()
                    if missing.isEmpty {
                        self.showAlert("Google account connected \u{2713}\n\nCalendar reminders, Google Tasks and follow-up meetings are all available.")
                    } else {
                        // Google lets the user untick individual permissions on
                        // the consent screen. Say which ones, rather than
                        // failing mysteriously later.
                        self.showAlert("Connected, but some permissions were declined:\n\n\(missing.map { "\u{2022} " + Self.scopeLabel($0) }.joined(separator: "\n"))\n\nReconnect and leave every box ticked to enable those.")
                    }
                }
            } else {
                let desc = (obj["error_description"] as? String) ?? (obj["error"] as? String) ?? "unknown error"
                DispatchQueue.main.async { self.showAlert("Token exchange failed: \(desc)") }
            }
        }.resume()
    }

    static func scopeLabel(_ scope: String) -> String {
        switch scope {
        case "https://www.googleapis.com/auth/calendar.readonly": return "Read your calendar (meeting reminders)"
        case "https://www.googleapis.com/auth/calendar.events": return "Create calendar events (follow-up meetings)"
        case "https://www.googleapis.com/auth/tasks": return "Create tasks (action items in Google Tasks)"
        default: return scope
        }
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

    // MARK: - UI

    func showSetupAlert() {
        let alert = NSAlert()
        alert.messageText = "Connect your Google account"
        alert.informativeText = """
        One-time setup:

        1. Open Google Cloud Console -> APIs & Services -> Credentials
        2. Create or pick a project, enable the Google Calendar API and the
           Google Tasks API
        3. OAuth consent screen -> External -> add yourself as a test user
        4. Credentials -> Create OAuth client ID -> "Desktop app"
        5. Download the JSON (or copy client_id + client_secret)
        6. Save it to ~/.nikxel/google_creds.json
        7. Menu bar -> Connect Google Account

        The downloaded Google JSON works as-is.
        """
        alert.addButton(withTitle: "Open Google Cloud Console")
        alert.addButton(withTitle: "Later")
        if alert.runOnTop() == .alertFirstButtonReturn,
           let url = URL(string: "https://console.cloud.google.com/apis/credentials") {
            NSWorkspace.shared.open(url)
        }
    }

    /// A bubble over the avatar, not a modal: these arrive while you're in
    /// another app (after a sync, a sign-in) and a modal would open behind it.
    func showAlert(_ text: String) {
        NikxelView.tell(icon: "🔗", title: "Google",
                        lines: text.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty },
                        lifetime: 30)
    }
}
