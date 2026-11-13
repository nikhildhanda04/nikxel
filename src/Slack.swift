import AppKit
import Network

/// Today's Slack messages for the end-of-day summary. The user signs in once
/// in the browser (Slack's own workspace picker and Allow page); after that
/// it's one `search.messages` query at summary time: no polling, no extra
/// browser, nothing running in between.
enum Slack {
    /// The shared Nikxel Slack app: PKCE on, user scope `search:read`, and
    /// `redirectURI` as its redirect URL. A client ID is public, so it can
    /// ship in the app; PKCE is what stands in for a client secret.
    static let clientId = ""
    /// Fixed, because Slack only redirects to a URL registered on the app.
    static let port: UInt16 = 47119
    static let redirectURI = "http://localhost:47119/slack"

    struct APIError: LocalizedError {
        let code: String
        var errorDescription: String? { code }
    }

    // MARK: - Tokens

    /// Kept out of settings.json and owner-only, like google_token.json: it
    /// reads every message the user can see.
    private static let tokenURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".nikxel/slack_token.json")

    private static func loadTokens() -> [String: Any]? {
        (try? Data(contentsOf: tokenURL)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }

    static var isConnected: Bool { loadTokens()?["access_token"] != nil }

    static func disconnect() { try? FileManager.default.removeItem(at: tokenURL) }

    /// Stores what `oauth.v2.access` returned, for both the first exchange
    /// (user token under `authed_user`) and a refresh (at the top level).
    @discardableResult
    private static func store(_ obj: [String: Any]) -> Bool {
        let t = (obj["authed_user"] as? [String: Any]) ?? obj
        guard let access = t["access_token"] as? String else { return false }
        var saved = loadTokens() ?? [:]
        saved["access_token"] = access
        if let r = t["refresh_token"] as? String { saved["refresh_token"] = r }
        if let e = t["expires_in"] as? Double { saved["expires_at"] = Date().timeIntervalSince1970 + e - 60 }
        if let team = (obj["team"] as? [String: Any])?["name"] as? String { saved["team"] = team }
        guard let data = try? JSONSerialization.data(withJSONObject: saved) else { return false }
        try? data.write(to: tokenURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tokenURL.path)
        return true
    }

    /// A working access token, refreshed first if it has expired. Blocking.
    private static func token() -> String? {
        guard let saved = loadTokens(), let access = saved["access_token"] as? String else { return nil }
        guard let exp = saved["expires_at"] as? Double, Date().timeIntervalSince1970 > exp,
              let refresh = saved["refresh_token"] as? String else { return access }
        // PKCE refresh tokens last 30 days; the daily summary refreshes well
        // inside that. A Mac left off for a month has to sign in again.
        guard case .success(let obj) = post("oauth.v2.access", [
            "grant_type": "refresh_token", "refresh_token": refresh, "client_id": clientId,
        ]), store(obj) else { return nil }
        return loadTokens()?["access_token"] as? String
    }

    // MARK: - Sign-in

    private static var listener: NWListener?

    /// Opens Slack's sign-in in the browser and waits on localhost for the
    /// redirect. `done` gets the workspace name, on the main thread.
    static func connect(done: @escaping (Result<String, Error>) -> Void) {
        guard !clientId.isEmpty else { done(.failure(APIError(code: "this build has no Slack app ID yet"))); return }
        listener?.cancel(); listener = nil
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.acceptLocalOnly = true
        guard let l = try? NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!) else {
            done(.failure(APIError(code: "port \(port) is busy"))); return
        }
        listener = l
        let state = UUID().uuidString
        let verifier = GoogleAuth.randomVerifier()

        l.newConnectionHandler = { conn in
            conn.start(queue: .main)
            conn.receive(minimumIncompleteLength: 1, maximumLength: 16384) { data, _, _, _ in
                guard let req = data.flatMap({ String(data: $0, encoding: .utf8) }),
                      req.hasPrefix("GET /slack") else { conn.cancel(); return }
                let code = GoogleAuth.queryParam(request: req, key: "code")
                let ok = code != nil && GoogleAuth.queryParam(request: req, key: "state") == state
                let body = "<html><body style='font-family:-apple-system;text-align:center;padding:60px'><h2>"
                    + (ok ? "Nikxel: Slack connected &#10003;</h2><p>You can close this tab.</p>" : "Slack sign-in failed</h2>")
                    + "</body></html>"
                let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                conn.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in conn.cancel() })
                l.cancel(); if listener === l { listener = nil }
                guard ok, let code = code else {
                    done(.failure(APIError(code: GoogleAuth.queryParam(request: req, key: "error") ?? "cancelled"))); return
                }
                DispatchQueue.global(qos: .userInitiated).async {
                    let result = post("oauth.v2.access", [
                        "code": code, "code_verifier": verifier, "client_id": clientId, "redirect_uri": redirectURI,
                    ])
                    DispatchQueue.main.async {
                        switch result {
                        case .success(let obj) where store(obj):
                            done(.success((obj["team"] as? [String: Any])?["name"] as? String ?? "Slack"))
                        case .success: done(.failure(APIError(code: "no user token in Slack's reply")))
                        case .failure(let e): done(.failure(e))
                        }
                    }
                }
            }
        }
        // Binding fails here, not at init.
        l.stateUpdateHandler = { s in
            if case .failed = s { l.cancel(); done(.failure(APIError(code: "port \(port) is busy"))) }
        }
        l.start(queue: .main)
        // An abandoned sign-in shouldn't hold the port.
        DispatchQueue.main.asyncAfter(deadline: .now() + 600) {
            if listener === l { l.cancel(); listener = nil }
        }

        var c = URLComponents(string: "https://slack.com/oauth/v2/authorize")!
        c.queryItems = [
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "user_scope", value: "search:read"),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: GoogleAuth.challenge(for: verifier)),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]
        NSWorkspace.shared.open(c.url!)
    }

    // MARK: - Messages

    /// One line per message on `day` (Slack's own idea of the day, in the
    /// user's Slack time zone), oldest first.
    static func messages(on day: String) -> [String] {
        guard let token = token() else { return [] }
        var lines: [String] = []
        // ponytail: newest 300 only; a big workspace's busy day gets trimmed,
        // page further if summaries start missing things.
        for page in 1...3 {
            guard case .success(let obj) = get("search.messages", token: token, query: [
                ("query", "on:\(day)"), ("sort", "timestamp"), ("sort_dir", "desc"),
                ("count", "100"), ("page", String(page)),
            ]), let m = obj["messages"] as? [String: Any],
                  let matches = m["matches"] as? [[String: Any]] else { break }
            for x in matches {
                let text = ((x["text"] as? String) ?? "").replacingOccurrences(of: "\n", with: " ")
                guard !text.isEmpty else { continue }
                let ch = x["channel"] as? [String: Any] ?? [:]
                let isDM = (ch["is_im"] as? Bool) == true || (ch["is_mpim"] as? Bool) == true
                let place = isDM ? "DM" : "#" + ((ch["name"] as? String) ?? "?")
                let ts = Double((x["ts"] as? String) ?? "") ?? 0
                let time = timeFmt.string(from: Date(timeIntervalSince1970: ts))
                lines.append("- [\(time)] \(place) — \((x["username"] as? String) ?? "?"): \(text.prefix(300))")
            }
            let pages = ((m["paging"] as? [String: Any])?["pages"] as? Int) ?? 1
            if page >= pages { break }
        }
        return lines.reversed()
    }

    private static let timeFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f
    }()

    // MARK: - HTTP

    private static func get(_ method: String, token: String, query: [(String, String)]) -> Result<[String: Any], Error> {
        var c = URLComponents(string: "https://slack.com/api/" + method)!
        c.queryItems = query.map { URLQueryItem(name: $0.0, value: $0.1) }
        var req = URLRequest(url: c.url!, timeoutInterval: 20)
        req.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        return send(req)
    }

    private static func post(_ method: String, _ form: [String: String]) -> Result<[String: Any], Error> {
        var req = URLRequest(url: URL(string: "https://slack.com/api/" + method)!, timeoutInterval: 20)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = GoogleAuth.formEncode(form).data(using: .utf8)
        return send(req)
    }

    /// Blocking: only ever called off the main thread.
    private static func send(_ req: URLRequest) -> Result<[String: Any], Error> {
        var result: Result<[String: Any], Error> = .failure(APIError(code: "no_response"))
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: req) { data, _, error in
            defer { done.signal() }
            if let error = error { result = .failure(error); return }
            guard let data = data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            result = (obj["ok"] as? Bool) == true
                ? .success(obj)
                : .failure(APIError(code: (obj["error"] as? String) ?? "unknown_error"))
        }.resume()
        done.wait()
        return result
    }
}
