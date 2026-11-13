import Foundation

/// Minimal Chrome DevTools Protocol client over WebSocket.
///
/// Why CDP instead of AppleScript + CGEvent:
///   - `Input.dispatchMouseEvent` and `Input.dispatchKeyEvent` send TRUSTED
///     events React accepts. No focus stealing, no clipboard hijack.
///   - Targets a specific tab in the background. Chrome can stay minimized.
///   - Survives multi-display / window-occlusion edge cases that broke the
///     CGEvent-at-screen-coords approach.
///
/// Requires Chrome launched with `--remote-debugging-port=9222`. We point at
/// an isolated profile dir so the user's main Chrome session is untouched.
final class CDPClient {
    enum CDPError: Error {
        case portClosed
        case noTab
        case send
        case timeout
        case payload(String)
    }

    private var ws: URLSessionWebSocketTask?
    private var nextID = 1
    private var pending: [Int: (Result<Any, Error>) -> Void] = [:]
    private let lock = NSLock()
    private let session = URLSession(configuration: .ephemeral)
    private(set) var targetURL: String?

    /// Connect to the first tab matching `urlContains`. Returns false if the
    /// debug port is unreachable or no matching tab exists.
    func connect(urlContains needle: String) -> Bool {
        guard let listURL = URL(string: "http://localhost:9222/json") else { return false }
        let req = URLRequest(url: listURL, timeoutInterval: 1.0)
        let sema = DispatchSemaphore(value: 0)
        var data: Data?
        session.dataTask(with: req) { d, _, _ in
            data = d; sema.signal()
        }.resume()
        _ = sema.wait(timeout: .now() + 1.5)
        guard let d = data,
              let arr = try? JSONSerialization.jsonObject(with: d) as? [[String: Any]] else {
            return false
        }
        guard let tab = arr.first(where: {
            ($0["url"] as? String)?.contains(needle) == true
        }) else { return false }
        guard let wsStr = tab["webSocketDebuggerUrl"] as? String,
              let wsURL = URL(string: wsStr) else { return false }
        targetURL = tab["url"] as? String
        let task = session.webSocketTask(with: wsURL)
        task.resume()
        ws = task
        receive()
        // No Runtime.enable: Runtime.evaluate works without it, and with it on
        // DevTools keeps every object WhatsApp Web logs to the console alive
        // and streams each console call over the socket, all day.
        return true
    }

    func disconnect() {
        ws?.cancel(with: .goingAway, reason: nil)
        ws = nil
        session.invalidateAndCancel()   // a session per client: let it go with it
    }

    var isConnected: Bool { ws != nil }

    private func receive() {
        ws?.receive { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let msg):
                var text = ""
                if case .string(let s) = msg { text = s }
                else if case .data(let d) = msg, let s = String(data: d, encoding: .utf8) { text = s }
                if let data = text.data(using: .utf8),
                   let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let id = obj["id"] as? Int {
                    self.lock.lock()
                    let cb = self.pending.removeValue(forKey: id)
                    self.lock.unlock()
                    if let cb = cb {
                        if let err = obj["error"] as? [String: Any] {
                            cb(.failure(CDPError.payload("\(err)")))
                        } else {
                            cb(.success(obj["result"] ?? [:]))
                        }
                    }
                }
                self.receive()
            case .failure:
                // Connection died. Caller will reconnect on next op, with a
                // new client -- so this one's session goes now.
                self.ws = nil
                self.session.invalidateAndCancel()
            }
        }
    }

    /// Synchronous send: blocks calling thread until response or timeout.
    @discardableResult
    func sendSync(_ method: String, params: [String: Any] = [:], timeout: TimeInterval = 5.0) -> Any? {
        let id: Int = lock.withLock {
            let i = nextID; nextID += 1; return i
        }
        let payload: [String: Any] = ["id": id, "method": method, "params": params]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let str = String(data: data, encoding: .utf8) else { return nil }

        let sema = DispatchSemaphore(value: 0)
        var out: Any?
        lock.lock()
        pending[id] = { result in
            if case let .success(v) = result { out = v }
            sema.signal()
        }
        lock.unlock()

        ws?.send(.string(str)) { _ in }
        _ = sema.wait(timeout: .now() + timeout)
        // Cleanup if it timed out so the slot doesn't leak.
        lock.lock()
        pending.removeValue(forKey: id)
        lock.unlock()
        return out
    }

    // MARK: - Convenience: Runtime.evaluate

    /// Evaluate JS in the target tab. Returns the result's string value, or
    /// nil on error. `returnByValue:true` ensures we get a serializable
    /// JSON-able primitive back (string / number / object) rather than a
    /// remote handle.
    func eval(_ expression: String) -> String? {
        let params: [String: Any] = [
            "expression": expression,
            "returnByValue": true,
            "awaitPromise": true
        ]
        guard let result = sendSync("Runtime.evaluate", params: params) as? [String: Any] else {
            return nil
        }
        if let obj = result["result"] as? [String: Any] {
            if let value = obj["value"] {
                if let s = value as? String { return s }
                if let data = try? JSONSerialization.data(withJSONObject: value),
                   let s = String(data: data, encoding: .utf8) {
                    return s
                }
                return "\(value)"
            }
        }
        return nil
    }

    // MARK: - Convenience: Input.dispatchMouseEvent

    /// Click at viewport-relative (x, y). `clickCount: 1` triggers React. CDP
    /// auto-dispatches pressed→released; we do both halves so React sees a
    /// full press cycle.
    func clickAt(x: Double, y: Double) {
        let common: [String: Any] = [
            "x": x, "y": y,
            "button": "left",
            "clickCount": 1
        ]
        var pressed = common
        pressed["type"] = "mousePressed"
        sendSync("Input.dispatchMouseEvent", params: pressed)
        var released = common
        released["type"] = "mouseReleased"
        sendSync("Input.dispatchMouseEvent", params: released)
    }

    // MARK: - Convenience: Input.insertText

    /// Insert literal text into the focused element. Equivalent to typing
    /// without going through individual key codes — works with Lexical /
    /// React contenteditables.
    func insertText(_ text: String) {
        sendSync("Input.insertText", params: ["text": text])
    }

    /// Press the Enter key. macOS native code 36 in CDP "windowsVirtualKeyCode"
    /// terms is 13 (VK_RETURN).
    func pressEnter() {
        let down: [String: Any] = [
            "type": "keyDown",
            "key": "Enter",
            "code": "Enter",
            "windowsVirtualKeyCode": 13,
            "nativeVirtualKeyCode": 13
        ]
        let up: [String: Any] = [
            "type": "keyUp",
            "key": "Enter",
            "code": "Enter",
            "windowsVirtualKeyCode": 13,
            "nativeVirtualKeyCode": 13
        ]
        sendSync("Input.dispatchKeyEvent", params: down)
        sendSync("Input.dispatchKeyEvent", params: up)
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock(); defer { unlock() }
        return body()
    }
}
