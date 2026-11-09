import Foundation
import AppKit

// MARK: - Data types

struct WAUnreadChat: Codable {
    let name: String
    var unread: Int
    let text: String
    var index: Int?
    /// Detected from the sidebar row, WITHOUT opening the chat -- opening one
    /// marks it read and hides it from the user's phone, which is exactly the
    /// damage a group filter is supposed to prevent.
    var isGroup: Bool
    /// True when the row carries WhatsApp's own @-mention badge, or the preview
    /// text names the user with an "@".
    var mentioned: Bool
}

/// A lightweight snapshot of a chat row's preview text (any chat, not just unread).
struct WAChatPreview: Codable {
    let name: String
    let preview: String
}

/// One row from WhatsApp Web's Calls tab.
struct WACall: Codable {
    let name: String
    let info: String      // e.g. "Missed voice call", "Outgoing video call"
    let timeText: String  // WhatsApp's own relative/absolute label, e.g. "10:42 am" or "Yesterday"
}

// MARK: - Isolated Chrome instance

/// We don't touch the user's main Chrome. Instead we launch a SEPARATE
/// Chrome process with `--remote-debugging-port=9222` and an isolated
/// `--user-data-dir`. User scans the WhatsApp QR once in that window; the bot
/// drives it via CDP entirely in the background.
enum ChromeBot {
    static let debugPort = 9222
    static var profileDir: String {
        NSHomeDirectory() + "/.nikxel/chrome-profile"
    }

    /// True if Chrome's DevTools port responds. Connection-level only —
    /// doesn't validate that a WhatsApp tab is open.
    static func isPortOpen() -> Bool {
        guard let url = URL(string: "http://localhost:\(debugPort)/json/version") else { return false }
        let req = URLRequest(url: url, timeoutInterval: 0.5)
        let sema = DispatchSemaphore(value: 0)
        var ok = false
        URLSession.shared.dataTask(with: req) { d, _, _ in
            if let d = d, !d.isEmpty { ok = true }
            sema.signal()
        }.resume()
        _ = sema.wait(timeout: .now() + 0.8)
        return ok
    }

    /// Launches the bot's isolated Chrome if the debug port isn't already
    /// open. The first launch opens an empty window — the user must navigate
    /// to web.whatsapp.com and scan the QR. Subsequent launches restore the
    /// session (the profile dir keeps cookies).
    ///
    /// We invoke the Chrome binary directly (not `open -na`) because `open`
    /// can attach to / get cleaned up alongside the user's main Chrome
    /// instance, dropping the debug listener.
    @discardableResult
    static func launchIfNeeded() -> Bool {
        if isPortOpen() { return true }
        try? FileManager.default.createDirectory(
            atPath: profileDir, withIntermediateDirectories: true)
        let chromeBin = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
        guard FileManager.default.isExecutableFile(atPath: chromeBin) else {
            cblog("ChromeBot: Chrome binary not at \(chromeBin)")
            return false
        }
        let task = Process()
        task.launchPath = chromeBin
        task.arguments = [
            "--remote-debugging-port=\(debugPort)",
            "--user-data-dir=\(profileDir)",
            "--no-first-run",
            "--no-default-browser-check",
            "https://web.whatsapp.com"
        ]
        // Detach stdio so the parent process death doesn't kill Chrome.
        task.standardOutput = FileHandle(forWritingAtPath: "/dev/null")
        task.standardError = FileHandle(forWritingAtPath: "/dev/null")
        do {
            try task.run()
        } catch {
            cblog("ChromeBot: failed to launch — \(error)")
            return false
        }
        // Wait up to ~6 s for the port to come up.
        for _ in 0..<12 {
            Thread.sleep(forTimeInterval: 0.5)
            if isPortOpen() { return true }
        }
        return false
    }
}

// MARK: - WhatsApp Web bridge (CDP-backed)

/// All WhatsApp Web interaction goes through one persistent CDP connection
/// to the isolated Chrome's WhatsApp tab. No focus stealing; no clipboard
/// hijack; no CGEvent screen-coord math.
enum ChromeWhatsApp {

    private static var cdp: CDPClient?
    private static let cdpLock = NSLock()

    /// A Swift string as a JS string literal, quotes included.
    private static func jsString(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\")
                 .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private static func ensureCDP() -> CDPClient? {
        cdpLock.lock(); defer { cdpLock.unlock() }
        if let c = cdp, c.isConnected { return c }
        guard ChromeBot.launchIfNeeded() else {
            cblog("CDP: bot Chrome not reachable on port \(ChromeBot.debugPort)")
            return nil
        }
        let c = CDPClient()
        if !c.connect(urlContains: "web.whatsapp.com") {
            cblog("CDP: no WhatsApp tab in bot Chrome. Open https://web.whatsapp.com in the bot window and scan the QR.")
            return nil
        }
        cdp = c
        cblog("CDP: connected to \(c.targetURL ?? "?")")
        return c
    }

    // MARK: - High-level API

    /// True once WhatsApp Web has a logged-in chat list visible (as opposed
    /// to showing the QR code or still loading). Used by the onboarding
    /// wizard to poll for "scan complete" without the user clicking anything.
    static func isLoggedIn() -> Bool {
        guard let c = ensureCDP() else { return false }
        let js = """
        (function(){
            if (document.querySelector('canvas[aria-label], div[data-ref]')) return 'false';
            return !!document.querySelector('#pane-side, [aria-label="Chat list"]') ? 'true' : 'false';
        })()
        """
        return c.eval(js) == "true"
    }

    /// Get all unread chats from the sidebar.
    ///
    /// Also reports whether each row is a group and whether the user was
    /// @-mentioned in it, so `ChatbotEngine` can drop group chatter before
    /// clicking anything.
    static func unreadChats() -> [WAUnreadChat] {
        guard let c = ensureCDP() else { return [] }
        let own = NikxelSettings.waOwnName
        let escapedSelf = jsString(own)
        // Mentions are written "@Firstname" far more often than "@Full Name",
        // so match on the first word too.
        let escapedFirst = jsString(own.split(separator: " ").first.map(String.init) ?? own)
        let js = """
        (function(){
            var SELF_NAME = \(escapedSelf);
            var SELF_FIRST = \(escapedFirst);
            var result = [];
            var labels = document.querySelectorAll('span[aria-label]');
            for (var i = 0; i < labels.length; i++) {
                var ar = labels[i].getAttribute('aria-label') || '';
                var m = ar.match(/(\\d+)\\s*unread/i);
                if (!m) continue;
                var row = labels[i].closest('[role="row"]');
                if (!row) continue;
                var titled = row.querySelectorAll('span[title]');
                var name = titled.length ? (titled[0].getAttribute('title') || '').trim() : '';
                if (!name) {
                    var dirEl = row.querySelector('span[dir="auto"]');
                    name = dirEl ? dirEl.textContent.trim() : '';
                }
                if (!name) continue;
                if (name === 'Message yourself' || name === SELF_NAME) continue;

                // WhatsApp Web shows the last message under the chat name, and
                // in a GROUP it is prefixed with the sender ("Asha: on my way").
                // One-to-one previews carry no prefix. That prefix is the only
                // group signal available without opening the chat, alongside
                // the default-group avatar icon.
                var preview = titled.length > 1 ? (titled[1].getAttribute('title') || '').trim() : '';
                if (!preview) preview = row.textContent.trim();
                var prefix = preview.match(/^([^:]{1,30}):\\s/);
                var prefixName = prefix ? prefix[1].trim() : '';
                var isGroup = !!row.querySelector('[data-icon="default-group"], [data-icon="group"]');
                if (!isGroup && prefixName
                    && prefixName !== 'You' && prefixName !== 'Draft'
                    && prefixName !== name
                    && !/^(https?|www)$/i.test(prefixName)) {
                    isGroup = true;
                }

                var mentioned = !!row.querySelector('[data-icon="mention"], [data-icon="mentioned"]')
                    || /mention/i.test(ar)
                    || !!row.querySelector('[aria-label*="mention" i], [aria-label*="Mention"]');
                if (!mentioned && SELF_FIRST) {
                    mentioned = preview.indexOf('@' + SELF_FIRST) >= 0
                        || preview.indexOf('@' + SELF_NAME) >= 0;
                }

                result.push({
                    name: name,
                    unread: parseInt(m[1]),
                    text: row.textContent.trim().substring(0, 300),
                    index: i,
                    isGroup: isGroup,
                    mentioned: mentioned
                });
            }
            return JSON.stringify(result.slice(0, 50));
        })()
        """
        guard let json = c.eval(js),
              let data = json.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([WAUnreadChat].self, from: data)) ?? []
    }

    /// Second opinion on "is the open conversation a group", taken after the
    /// chat is on screen: two or more distinct senders in the loaded history is
    /// something a one-to-one chat cannot produce. Backs up the sidebar
    /// heuristic before a reply actually goes out -- by this point the chat has
    /// already been marked read, but an unwanted reply is the worse half.
    static func openChatIsGroup() -> Bool {
        guard let c = ensureCDP() else { return false }
        let js = """
        (function(){
            if (document.querySelector('header [data-icon="default-group"], header [data-icon="group"]')) return 'true';
            var bubbles = document.querySelectorAll('.copyable-text[data-pre-plain-text]');
            var senders = {};
            for (var i = 0; i < bubbles.length; i++) {
                var pre = bubbles[i].getAttribute('data-pre-plain-text') || '';
                var m = pre.match(/^\\[[^\\]]+\\]\\s*(.+?):\\s*$/);
                if (m) senders[m[1].trim()] = 1;
            }
            return Object.keys(senders).length > 2 ? 'true' : 'false';
        })()
        """
        return c.eval(js) == "true"
    }

    /// Open the chat for `name`. Returns a rect (viewport coords) of the
    /// clicked row so CDP `Input.dispatchMouseEvent` can target it without
    /// any screen-coord math.
    @discardableResult
    static func clickChat(name: String) -> Bool {
        guard let c = ensureCDP() else { return false }
        let escaped = name
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        // Scroll the row into view (the chat list is virtualized) then
        // return its center point in viewport coords. CDP dispatches the
        // mouse event at viewport coords directly.
        let js = """
        (function(){
            var target = \"\(escaped)\";
            var rows = document.querySelectorAll('[role="row"]');
            for (var i = 0; i < rows.length; i++) {
                var titleEl = rows[i].querySelector('span[title]');
                var n = titleEl ? (titleEl.getAttribute('title') || '').trim() : '';
                if (!n) {
                    var dirEl = rows[i].querySelector('span[dir="auto"]');
                    n = dirEl ? dirEl.textContent.trim() : '';
                }
                if (n === target) {
                    var cell = rows[i].querySelector('[role="gridcell"]') || rows[i];
                    cell.scrollIntoView({block: 'center', behavior: 'instant'});
                    var r = cell.getBoundingClientRect();
                    return JSON.stringify({x: r.x + r.width/2, y: r.y + r.height/2});
                }
            }
            return '';
        })()
        """
        guard let json = c.eval(js),
              !json.isEmpty,
              let data = json.data(using: .utf8),
              let pt = try? JSONDecoder().decode([String: Double].self, from: data),
              let x = pt["x"], let y = pt["y"] else {
            cblog("CDP: clickChat row not found for '\(name)'")
            return false
        }
        // Brief wait for scroll to settle before clicking.
        Thread.sleep(forTimeInterval: 0.15)
        c.clickAt(x: x, y: y)
        Thread.sleep(forTimeInterval: 0.6)
        return true
    }

    /// Read the contact name of the conversation currently open in the
    /// right pane. Parsed from the input's `aria-label`.
    static func conversationHeader() -> String? {
        guard let c = ensureCDP() else { return nil }
        let js = """
        (function(){
            var input = document.querySelector('[contenteditable="true"][aria-label]');
            if (input) {
                var ar = input.getAttribute('aria-label') || '';
                var m = ar.match(/^Type a message to (.+)$/);
                if (m) return m[1].trim();
            }
            var headers = document.querySelectorAll('header');
            for (var i = 0; i < headers.length; i++) {
                if (headers[i].querySelector('[title="Profile details"]')) {
                    var s = headers[i].querySelector('span');
                    if (s) return s.textContent.trim();
                }
            }
            return '';
        })()
        """
        return c.eval(js)
    }

    /// Read the last `count` INCOMING messages from the open conversation.
    ///
    /// WhatsApp Web no longer uses `.message-in/.message-out` classes. Each
    /// bubble carries a `.copyable-text[data-pre-plain-text]` div whose attr
    /// has the canonical form `"[12:34 pm, 18/06/2026] Sender Name: "`. We
    /// parse the sender out and drop bubbles authored by `userOwnName` so
    /// the bot doesn't quote itself or the user's own prior messages.
    static func readMessages(count: Int = 6, userOwnName: String = NikxelSettings.waOwnName) -> [String] {
        guard let c = ensureCDP() else { return [] }
        let escapedSelf = userOwnName
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let js = """
        (function(){
            var SELF = \"\(escapedSelf)\";
            var bubbles = Array.from(document.querySelectorAll('.copyable-text[data-pre-plain-text]'));
            var inbound = [];
            // Walk newest → oldest, keep only inbound, stop once we have N.
            for (var i = bubbles.length - 1; i >= 0 && inbound.length < \(count); i--) {
                var b = bubbles[i];
                var pre = b.getAttribute('data-pre-plain-text') || '';
                var m = pre.match(/^\\[[^\\]]+\\]\\s*(.+?):\\s*$/);
                if (!m) continue;
                var sender = m[1].trim();
                if (sender === SELF || sender.indexOf(SELF) === 0) continue;
                var txt = (b.textContent || '').trim();
                // Strip the trailing "12:34 pm" timestamp WhatsApp appends
                // inside the bubble's textContent.
                txt = txt.replace(/\\s*\\d{1,2}:\\d{2}\\s*[ap]m\\s*$/i, '').trim();
                if (txt) inbound.unshift(txt);
            }
            return JSON.stringify(inbound);
        })()
        """
        guard let json = c.eval(js),
              let data = json.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }

    /// Snapshot of every visible chat row's preview text, NOT just unread
    /// ones — used by `WhatsAppActivityLogger` to build a running picture of
    /// the day's chats (including ones already read on the phone) for the
    /// daily summary.
    static func allChatsPreview(limit: Int = 60) -> [WAChatPreview] {
        guard let c = ensureCDP() else { return [] }
        let js = """
        (function(){
            var result = [];
            var rows = document.querySelectorAll('[role="row"]');
            for (var i = 0; i < rows.length && result.length < \(limit); i++) {
                var row = rows[i];
                var titleEl = row.querySelector('span[title]');
                var name = titleEl ? (titleEl.getAttribute('title') || '').trim() : '';
                if (!name) {
                    var dirEl = row.querySelector('span[dir="auto"]');
                    name = dirEl ? dirEl.textContent.trim() : '';
                }
                if (!name || name === 'Message yourself') continue;
                result.push({
                    name: name,
                    preview: row.textContent.trim().substring(0, 300)
                });
            }
            return JSON.stringify(result);
        })()
        """
        guard let json = c.eval(js),
              let data = json.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([WAChatPreview].self, from: data)) ?? []
    }

    /// Switch the left sidebar from Chats to the Calls tab. WhatsApp Web's
    /// nav rail exposes it as a button labeled "Calls".
    @discardableResult
    private static func openCallsTab() -> Bool {
        guard let c = ensureCDP() else { return false }
        let js = """
        (function(){
            var btn = document.querySelector('button[aria-label="Calls"]')
                || document.querySelector('[aria-label="Calls"]');
            if (!btn) return 'not_found';
            btn.click();
            return 'ok';
        })()
        """
        let result = c.eval(js) ?? ""
        if result != "ok" {
            cblog("CDP: callLog — Calls tab button not found (\(result)); WhatsApp Web DOM may have changed")
            return false
        }
        Thread.sleep(forTimeInterval: 0.6)
        return true
    }

    /// Switch back to the Chats tab — called after reading the call log so
    /// `ChatbotEngine`'s unread-chat polling (which assumes the Chats list
    /// is on screen) isn't left looking at the Calls tab.
    @discardableResult
    static func openChatsTab() -> Bool {
        guard let c = ensureCDP() else { return false }
        let js = """
        (function(){
            var btn = document.querySelector('button[aria-label="Chats"]')
                || document.querySelector('[aria-label="Chats"]');
            if (!btn) return 'not_found';
            btn.click();
            return 'ok';
        })()
        """
        return (c.eval(js) ?? "") == "ok"
    }

    /// Read the call log (Calls tab). WhatsApp Web exposes no call
    /// audio/transcript via the DOM — only metadata: caller, call type
    /// (missed/incoming/outgoing, voice/video), and WhatsApp's own time
    /// label. Best-effort selectors; WhatsApp Web's DOM changes over time,
    /// so an empty result here doesn't necessarily mean there were no calls.
    static func callLog(limit: Int = 30) -> [WACall] {
        guard openCallsTab(), let c = ensureCDP() else { return [] }
        let js = """
        (function(){
            var result = [];
            var rows = document.querySelectorAll('[role="row"], [role="listitem"]');
            for (var i = 0; i < rows.length && result.length < \(limit); i++) {
                var row = rows[i];
                var titleEl = row.querySelector('span[title]') || row.querySelector('span[dir="auto"]');
                var name = titleEl ? (titleEl.getAttribute('title') || titleEl.textContent || '').trim() : '';
                if (!name) continue;
                var spans = Array.from(row.querySelectorAll('span'))
                    .map(function(s){ return (s.textContent || '').trim(); })
                    .filter(function(s){ return s.length > 0; });
                var info = '', timeText = '';
                for (var j = 0; j < spans.length; j++) {
                    if (spans[j] === name) continue;
                    if (/\\b(am|pm)\\b/i.test(spans[j]) || /yesterday|today|\\d{1,2}\\/\\d{1,2}/i.test(spans[j])) {
                        timeText = spans[j];
                    } else if (!info && spans[j].length < 60) {
                        info = spans[j];
                    }
                }
                result.push({name: name, info: info, timeText: timeText});
            }
            return JSON.stringify(result);
        })()
        """
        guard let json = c.eval(js),
              let data = json.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([WACall].self, from: data)) ?? []
    }

    /// Send a reply to the open conversation. Returns false if the chat has
    /// no reply input (read-only business/broadcast/channel chats expose no
    /// contenteditable footer — bot must skip them, not retry).
    static func sendMessage(_ text: String) -> Bool {
        guard let c = ensureCDP() else { return false }
        let focusJS = """
        (function(){
            var input = document.querySelector('[contenteditable="true"][data-tab="10"]')
                || document.querySelector('footer [contenteditable="true"]')
                || document.querySelector('[contenteditable="true"]');
            if (!input) return 'no_input';
            input.focus();
            return 'ok';
        })()
        """
        let focusResult = c.eval(focusJS) ?? ""
        if focusResult == "no_input" {
            cblog("CDP: sendMessage skipped — no reply input (read-only chat)")
            return false
        }
        guard focusResult == "ok" else {
            cblog("CDP: sendMessage focus failed (got '\(focusResult)')")
            return false
        }
        Thread.sleep(forTimeInterval: 0.1)
        c.insertText(text)
        Thread.sleep(forTimeInterval: 0.15)
        c.pressEnter()
        return true
    }

    /// No-op; kept for API compatibility. We never need to bring Chrome to
    /// front anymore — the bot Chrome can stay minimized.
    static func activate() {}
}
