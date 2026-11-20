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
    /// Who sent the last message, when the row says so. Groups only -- a
    /// one-to-one row has no sender element, which is how `isGroup` is decided.
    var sender: String
    /// The last message, bidi control marks stripped.
    var preview: String
}

/// A lightweight snapshot of a chat row's preview text (any chat, not just unread).
/// One bubble in the open chat. `at` is nil when WhatsApp gave no timestamp
/// (a row continuing the one above) or it didn't parse.
struct WAMessage: Equatable {
    let outgoing: Bool
    let at: Date?
    let text: String
}

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

    /// Chromium-family browsers that honour `--remote-debugging-port` and
    /// `--user-data-dir`, in the order we'd rather use them. Chrome first
    /// because it's the one this was built and tested against; the rest are the
    /// same engine behind different branding and behave identically for our
    /// purposes (one tab, one CDP socket, no extensions).
    ///
    /// Arc is deliberately absent despite being Chromium: it ignores
    /// `--user-data-dir`, so there is no way to get an isolated profile out of
    /// it, and an un-isolated profile would mean driving the user's own logged
    /// -in browser. Safari and Firefox are absent because neither speaks CDP.
    static let supportedBrowsers: [(name: String, app: String, binary: String)] = [
        ("Google Chrome",   "Google Chrome.app",         "Google Chrome"),
        ("Brave",           "Brave Browser.app",         "Brave Browser"),
        ("Microsoft Edge",  "Microsoft Edge.app",        "Microsoft Edge"),
        ("Chromium",        "Chromium.app",              "Chromium"),
        ("Vivaldi",         "Vivaldi.app",               "Vivaldi"),
        ("Opera",           "Opera.app",                 "Opera"),
        ("Chrome Beta",     "Google Chrome Beta.app",    "Google Chrome Beta"),
        ("Chrome Canary",   "Google Chrome Canary.app",  "Google Chrome Canary"),
    ]

    /// First installed browser from `supportedBrowsers`, or nil if none is.
    /// Checks /Applications and ~/Applications, which is where a user-local
    /// install lands.
    static func availableBrowser() -> (name: String, path: String)? {
        let roots = ["/Applications",
                     NSHomeDirectory() + "/Applications"]
        for b in supportedBrowsers {
            for root in roots {
                let path = "\(root)/\(b.app)/Contents/MacOS/\(b.binary)"
                if FileManager.default.isExecutableFile(atPath: path) {
                    return (b.name, path)
                }
            }
        }
        return nil
    }

    /// What to tell the user when none is installed. The old behaviour was to
    /// log to a file nobody reads and leave the setup wizard spinning on
    /// "Waiting for QR scan…" forever, which looks like a hang.
    static let missingBrowserMessage = """
    WhatsApp auto-replies need a Chromium-based browser installed — Nikxel runs     WhatsApp Web in its own isolated profile so it never touches your normal     browsing.

    Any one of these works: Google Chrome, Brave, Microsoft Edge, Chromium,     Vivaldi or Opera. Safari and Firefox can't be driven this way, and Arc     can't be given a separate profile.

    Everything else in Nikxel — recording, transcription, summaries, Google     Tasks — works without this.
    """

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

    /// Launches the bot's isolated browser if the debug port isn't already
    /// open. The first launch opens an empty window — the user must navigate
    /// to web.whatsapp.com and scan the QR. Subsequent launches restore the
    /// session (the profile dir keeps cookies).
    ///
    /// We invoke the binary directly (not `open -na`) because `open` can attach
    /// to / get cleaned up alongside the user's main browser instance, dropping
    /// the debug listener.
    private static var lastLaunchAttempt: Date?
    private static let launchLock = NSLock()

    private static func waitForPort(_ seconds: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if isPortOpen() { return true }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return false
    }

    /// Close every tab but WhatsApp: links opened from chats and a stray
    /// New Tab each keep a renderer alive (15-75 MB each, measured).
    static func closeStrayTabs() {
        guard let list = URL(string: "http://localhost:\(debugPort)/json/list"),
              let data = try? Data(contentsOf: list),
              let tabs = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return }
        for t in tabs where t["type"] as? String == "page" {
            guard let id = t["id"] as? String, let url = t["url"] as? String,
                  !url.contains("web.whatsapp.com"),
                  let close = URL(string: "http://localhost:\(debugPort)/json/close/\(id)") else { continue }
            _ = try? Data(contentsOf: close)
            cblog("ChromeBot: closed stray tab \(url.prefix(80))")
        }
    }

    /// Quits the bot browser (only the one on our profile, never the user's
    /// own) and waits for its debug port to close.
    static func quit() {
        let kill = Process()
        kill.launchPath = "/usr/bin/pkill"
        kill.arguments = ["-f", "user-data-dir=\(profileDir)"]
        try? kill.run(); kill.waitUntilExit()
        let deadline = Date().addingTimeInterval(5)
        while isPortOpen() && Date() < deadline { Thread.sleep(forTimeInterval: 0.3) }
    }

    @discardableResult
    static func launchIfNeeded() -> Bool {
        if isPortOpen() { return true }
        launchLock.lock(); defer { launchLock.unlock() }
        if isPortOpen() { return true }   // another caller got there first

        // A cold browser opening a brand-new profile takes well over the 6s
        // this used to allow: measured at ~15s on a first run. Returning false
        // then made the setup wizard accuse the user of a port conflict, and
        // had the engine fire a second launch at the same --user-data-dir. Wait
        // on the instance already starting instead of racing it.
        if let last = lastLaunchAttempt, Date().timeIntervalSince(last) < 90 {
            cblog("ChromeBot: a launch is already in flight — waiting for port \(debugPort)")
            return waitForPort(25)
        }

        try? FileManager.default.createDirectory(
            atPath: profileDir, withIntermediateDirectories: true)
        guard let browser = availableBrowser() else {
            cblog("ChromeBot: no Chromium-based browser installed (looked for \(supportedBrowsers.map(\.name).joined(separator: ", ")))")
            return false
        }
        let task = Process()
        task.launchPath = browser.path
        task.arguments = [
            "--remote-debugging-port=\(debugPort)",
            "--user-data-dir=\(profileDir)",
            "--no-first-run",
            "--no-default-browser-check",
            // One WhatsApp tab needs none of Chrome's own background services:
            // fewer utility processes, no model or component downloads. Not
            // the keychain flags -- those would make the saved login unreadable.
            "--disable-extensions",
            "--disable-background-networking",
            "--disable-component-update",
            "--disable-sync",
            "--disable-default-apps",
            "--no-pings",
            // No spare renderer kept warm for a next tab that never comes.
            "--disable-features=Translate,MediaRouter,OptimizationHints,OptimizationGuideModelDownloading,AutofillServerCommunication,SpareRendererForSitePerProcess",
            // An app window: WhatsApp on its own, no tabs or address bar --
            // whose popup alone was two preloaded renderers (~170 MB).
            "--app=https://web.whatsapp.com"
        ]
        // Detach stdio so the parent process death doesn't kill the browser.
        task.standardOutput = FileHandle(forWritingAtPath: "/dev/null")
        task.standardError = FileHandle(forWritingAtPath: "/dev/null")
        do {
            try task.run()
        } catch {
            cblog("ChromeBot: failed to launch \(browser.name) — \(error)")
            return false
        }
        lastLaunchAttempt = Date()
        cblog("ChromeBot: launched \(browser.name)")
        let up = waitForPort(30)
        if !up { cblog("ChromeBot: \(browser.name) started but port \(debugPort) never opened") }
        return up
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
        // Never connected WhatsApp: don't pop the bot browser open on every
        // poll. Setup launches it itself; until then only use one already up.
        let connected = NikxelSettings.whatsappConnected
        guard connected ? ChromeBot.launchIfNeeded() : ChromeBot.isPortOpen() else {
            if connected { cblog("CDP: bot Chrome not reachable on port \(ChromeBot.debugPort)") }
            return nil
        }
        let c = CDPClient()
        if !c.connect(urlContains: "web.whatsapp.com") {
            c.disconnect()
            cblog("CDP: no WhatsApp tab in bot Chrome. Open https://web.whatsapp.com in the bot window and scan the QR.")
            return nil
        }
        cdp = c
        cblog("CDP: connected to \(c.targetURL ?? "?")")
        ChromeBot.closeStrayTabs()
        return c
    }

    /// Logs WhatsApp out of Nikxel for good: auto-replies off, the bot
    /// browser quit, and its profile (the WhatsApp session) deleted, so
    /// nothing relaunches it until the user connects again from setup.
    /// Call on the main thread (the bot's poll timer lives there); `done`
    /// runs on main once the browser is gone.
    static func disconnect(done: @escaping () -> Void) {
        ChatbotEngine.shared.isEnabled = false
        NikxelSettings.whatsappConnected = false
        DispatchQueue.global(qos: .userInitiated).async {
            cdpLock.lock(); cdp?.disconnect(); cdp = nil; cdpLock.unlock()
            ChromeBot.quit()
            try? FileManager.default.removeItem(atPath: ChromeBot.profileDir)
            // A chat poll in flight when the browser went down sets this back.
            NikxelSettings.whatsappConnected = false
            cblog("ChromeWhatsApp: disconnected — bot browser quit, session removed")
            DispatchQueue.main.async(execute: done)
        }
    }

    // MARK: - Sharing a file

    /// Types `q` into WhatsApp's own search box and returns what it finds
    /// (chats, then contacts), the box cleared again. Empty `q`: the chat
    /// list as it stands, most recent first.
    static func searchChats(_ q: String) -> [String] {
        guard let c = ensureCDP() else { return [] }
        let js = """
        (async function(){
            var q = \(jsString(q));
            var s = document.querySelector('#side input[aria-label]');
            if (q && s) { s.focus(); s.select(); document.execCommand('insertText', false, q);
                          await new Promise(function(r){ setTimeout(r, 1500); }); }
            var seen = {}, out = [];
            document.querySelectorAll('#pane-side [role="row"], #side [role="listitem"]').forEach(function(r){
                var t = r.querySelector('span[title]'); var n = t ? t.getAttribute('title').trim() : '';
                if (n && !seen[n] && out.length < 25) { seen[n] = 1; out.push(n); }
            });
            if (q && s) { s.select(); document.execCommand('delete'); }
            return JSON.stringify(out);
        })()
        """
        guard let json = c.eval(js), let data = json.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }

    /// Opens `name`'s chat through the search box, so it works for anyone,
    /// not only the chats the list has rendered. True once it's open.
    static func openChatBySearch(_ name: String) -> Bool {
        guard let c = ensureCDP() else { return false }
        let find = """
        (async function(){
            var q = \(jsString(name));
            var s = document.querySelector('#side input[aria-label]');
            if (!s) return '';
            s.focus(); s.select(); document.execCommand('insertText', false, q);
            await new Promise(function(r){ setTimeout(r, 1500); });
            var rows = document.querySelectorAll('#pane-side [role="row"], #side [role="listitem"]');
            for (var i = 0; i < rows.length; i++) {
                var t = rows[i].querySelector('span[title]');
                if (t && t.getAttribute('title').trim() === q) {
                    var r = rows[i].getBoundingClientRect();
                    return JSON.stringify({x: r.x + r.width/2, y: r.y + r.height/2});
                }
            }
            return '';
        })()
        """
        let clear = "(function(){ var s = document.querySelector('#side input[aria-label]'); if (s) { s.select(); document.execCommand('delete'); } return 'ok'; })()"
        guard let json = c.eval(find), let data = json.data(using: .utf8),
              let pt = try? JSONDecoder().decode([String: Double].self, from: data),
              let x = pt["x"], let y = pt["y"] else {
            _ = c.eval(clear)
            cblog("CDP: openChatBySearch found no chat named '\(name)'")
            return false
        }
        c.clickAt(x: x, y: y)
        Thread.sleep(forTimeInterval: 0.8)
        _ = c.eval(clear)
        let open = conversationHeader()?.lowercased() ?? ""
        return open == name.lowercased() || open.contains(name.lowercased())
    }

    /// Attaches `data` as a document to the open chat and sends it: a paste
    /// of the file, which opens WhatsApp's own preview, then its Send.
    static func sendFile(named fileName: String, data: Data, type: String) -> Bool {
        guard let c = ensureCDP() else { return false }
        let js = """
        (async function(){
            var input = document.querySelector('footer [contenteditable="true"]');
            if (!input) return '';
            input.focus();
            var bin = atob(\(jsString(data.base64EncodedString())));
            var bytes = new Uint8Array(bin.length);
            for (var i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
            var dt = new DataTransfer();
            dt.items.add(new File([bytes], \(jsString(fileName)), {type: \(jsString(type))}));
            input.dispatchEvent(new ClipboardEvent('paste', {clipboardData: dt, bubbles: true, cancelable: true}));
            for (var t = 0; t < 15; t++) {
                await new Promise(function(r){ setTimeout(r, 200); });
                var b = document.querySelector('[aria-label^="Send"][role="button"]');
                if (b) { var r = b.getBoundingClientRect(); return JSON.stringify({x: r.x + r.width/2, y: r.y + r.height/2}); }
            }
            return '';
        })()
        """
        guard let json = c.eval(js), let d = json.data(using: .utf8),
              let pt = try? JSONDecoder().decode([String: Double].self, from: d),
              let x = pt["x"], let y = pt["y"] else {
            cblog("CDP: sendFile — WhatsApp's file preview never opened")
            return false
        }
        c.clickAt(x: x, y: y)
        Thread.sleep(forTimeInterval: 1.0)
        // A window that's minimised can miss a coordinate click; press it from the page.
        _ = c.eval("(function(){ var b = document.querySelector('[aria-label^=\"Send\"][role=\"button\"]'); if (b) b.click(); return 'ok'; })()")
        cblog("CDP: sent file \(fileName)")
        return true
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

    /// WhatsApp Web's JS heap, in MB; 0 when it can't be read.
    static func heapMB() -> Int {
        guard let c = ensureCDP() else { return 0 }
        return Int(c.eval("String(Math.round(((performance.memory || {}).usedJSHeapSize || 0) / 1e6))") ?? "") ?? 0
    }

    /// Reload WhatsApp Web and block until its chat list is back (or 60s).
    @discardableResult
    static func reloadPage() -> Bool {
        guard let c = ensureCDP() else { return false }
        ChromeBot.closeStrayTabs()
        _ = c.eval("setTimeout(function(){ location.reload(); }, 0), 'ok'")
        Thread.sleep(forTimeInterval: 3)
        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline {
            if isLoggedIn() { return true }
            Thread.sleep(forTimeInterval: 1)
        }
        return false
    }

    /// Get all unread chats from the sidebar.
    ///
    /// Also reports whether each row is a group and whether the user was
    /// @-mentioned in it, so `ChatbotEngine` can drop group chatter before
    /// clicking anything.
    ///
    /// The group test reads WhatsApp's own markup rather than guessing from
    /// text. Inside `[data-testid="last-msg-status"]` a group row looks like:
    ///
    ///     <span title="Happy Diwali" data-testid="last-msg-status">
    ///       <div><div><span dir="auto">PM Prince</span></div></div>
    ///       <span>:&nbsp;</span>
    ///       <span dir="ltr">Happy Diwali</span>
    ///
    /// A one-to-one row has no sender element and no ":&nbsp;" separator -- it
    /// goes straight to the message, or to a `chat-msg-symbol` for media. That
    /// separator span is therefore the signal, and the sender name next to it
    /// comes out for free.
    ///
    /// An earlier version read the sender out of the row's `title` attribute.
    /// It never worked: the title holds the message only, so every group in a
    /// real chat list came back as a one-to-one.
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
            // WhatsApp wraps every title in bidi isolates; a regex anchored at
            // ^ would otherwise be looking at U+202A.
            var BIDI = /[\\u202A-\\u202E\\u200E\\u200F\\u2066-\\u2069]/g;
            var result = [];
            var labels = document.querySelectorAll('#pane-side span[aria-label]');   // the chat list only
            for (var i = 0; i < labels.length; i++) {
                var ar = labels[i].getAttribute('aria-label') || '';
                var m = ar.match(/(\\d+)\\s*unread/i);
                if (!m) continue;
                var row = labels[i].closest('[role="row"]');
                if (!row) continue;

                // The row has TWO span[title]: the chat name and the message
                // preview. Pick the name by excluding the preview rather than
                // by document order.
                var nameEl = row.querySelector('span[title]:not([data-testid="last-msg-status"])');
                var name = nameEl ? (nameEl.getAttribute('title') || '').replace(BIDI, '').trim() : '';
                if (!name) {
                    var dirEl = row.querySelector('span[dir="auto"]');
                    name = dirEl ? dirEl.textContent.trim() : '';
                }
                if (!name) continue;
                if (name === 'Message yourself' || name === SELF_NAME) continue;

                var status = row.querySelector('[data-testid="last-msg-status"]');
                var preview = status ? (status.getAttribute('title') || '').replace(BIDI, '').trim() : '';

                var isGroup = false, sender = '';
                if (status) {
                    for (var k = 0; k < status.children.length; k++) {
                        // trim() drops the &nbsp;, leaving a bare colon.
                        if ((status.children[k].textContent || '').trim() === ':') {
                            isGroup = true;
                            break;
                        }
                    }
                    if (isGroup) {
                        var auto = status.querySelector('span[dir="auto"]');
                        if (auto) sender = (auto.textContent || '').replace(BIDI, '').trim();
                    }
                }
                if (!isGroup) {
                    isGroup = !!row.querySelector('[data-icon="default-group"], [data-icon="group"]');
                }

                var mentioned = !!row.querySelector('[data-icon*="mention" i], [aria-label*="mention" i]')
                    || /mention/i.test(ar);
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
                    mentioned: mentioned,
                    sender: sender,
                    preview: preview
                });
            }
            return JSON.stringify(result.slice(0, 50));
        })()
        """
        guard let json = c.eval(js),
              let data = json.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([WAUnreadChat].self, from: data)) ?? []
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

    /// Name and group-ness of the conversation currently open in the right
    /// pane, read from the message box's own aria-label.
    ///
    /// WhatsApp writes "Type a message to Kirti Forklyft" for a one-to-one and
    /// "Type a message to group Warrior Tennis" for a group. That one word is
    /// the only authoritative group signal in the page -- both heuristics tried
    /// before it (a `default-group` icon, counting distinct senders in the
    /// loaded history) returned false on real groups.
    static func openConversation() -> (name: String, isGroup: Bool)? {
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
        guard let label = c.eval(js), !label.isEmpty else { return nil }
        return parseConversationLabel(label)
    }

    /// Split out from `openConversation` so the qualifier handling can be
    /// checked against the exact strings WhatsApp was observed to emit --
    /// see check_wa_bot.swift.
    static func parseConversationLabel(_ label: String) -> (name: String, isGroup: Bool) {
        let trimmed = label.trimmingCharacters(in: .whitespaces)
        if trimmed.lowercased().hasPrefix("group ") {
            return (String(trimmed.dropFirst("group ".count)).trimmingCharacters(in: .whitespaces), true)
        }
        return (trimmed, false)
    }

    /// Just the name, with any "group " qualifier removed.
    ///
    /// Leaving that word in broke the engine's "am I in the right chat" check
    /// for every group: "group Warrior Tennis" never matched "Warrior Tennis",
    /// so a tagged group message the user had explicitly allowed was aborted
    /// instead of answered.
    static func conversationHeader() -> String? {
        openConversation()?.name
    }

    /// Whether the open conversation is a group.
    ///
    /// ponytail: the "group " qualifier is English, so this reads as a
    /// one-to-one under a non-English WhatsApp UI. The sidebar check in
    /// `unreadChats` is language-independent and is the one that actually
    /// gates replies; this is the backstop. Upgrade path is matching the label
    /// against the clicked chat name and treating any leading extra word as
    /// the qualifier, whatever language it is in.
    static func openChatIsGroup() -> Bool {
        openConversation()?.isGroup ?? false
    }

    /// Read the last `count` INCOMING messages from the open conversation.
    ///
    /// Direction is resolved per row, in this order:
    ///
    /// 1. `data-pre-plain-text` -- `"[12:34 pm, 18/06/2026] Sender Name: "`.
    ///    Names the sender outright. Present for text from a resolvable sender,
    ///    which covers saved contacts and group members.
    /// 2. `tail-in` / `tail-out`, the SVG title on a bubble's tail.
    /// 3. Inherited from the row above.
    ///
    /// Step 3 is not a nicety. A tail marks only the FIRST bubble of a run, so
    /// in any run of two or more the NEWEST message carries neither signal --
    /// and that is exactly the message the bot is answering. Measured on a real
    /// group, the latest message was dropped without it. Hence the walk is
    /// oldest-to-newest, carrying direction forward, rather than newest-first.
    ///
    /// A row is only taken if it has `.selectable-text`. Using the row's own
    /// textContent instead pulled in the SVG title of every icon on the bubble:
    /// a voice note read as "ic-downloadic-headphones-filledic-bookmark-filled
    /// 9:27 pm". Stickers, images and voice notes therefore yield nothing,
    /// which is right -- there is no text in them to reply to.
    static func readMessages(count: Int = 6, userOwnName: String = NikxelSettings.waOwnName) -> [String] {
        Array(readThread(userOwnName: userOwnName).filter { !$0.outgoing }.map(\.text).suffix(count))
    }

    /// Appends the user's own sent bubbles from the open chat to ~/.nikxel/wa_sent.jsonl,
    /// skipping texts already in the log's recent tail.
    // ponytail: captures sent messages only from the chat currently open in the bot's browser; broader backfill is a follow-up if voice signal is thin.
    static func logSentFromOpenThread(userOwnName: String = NikxelSettings.waOwnName) {
        let sent = readThread(userOwnName: userOwnName).filter { $0.outgoing }.map(\.text)
        guard !sent.isEmpty else { return }
        var seen = Set(TwinProfile.recentSentMessages(limit: 200))
        var lines = Data()
        for text in sent where !text.isEmpty && seen.insert(text).inserted {
            guard let d = try? JSONSerialization.data(withJSONObject: ["t": Date().timeIntervalSince1970, "text": text]) else { continue }
            lines.append(d); lines.append(0x0A)
        }
        guard !lines.isEmpty else { return }
        let url = URL(fileURLWithPath: TwinProfile.sentFile)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(lines); try? h.close()
        } else { try? lines.write(to: url) }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// Every rendered bubble in the open chat, both directions, oldest first.
    static func readThread(userOwnName: String = NikxelSettings.waOwnName) -> [WAMessage] {
        guard let c = ensureCDP() else { return [] }
        let escapedSelf = jsString(userOwnName)
        let js = """
        (function(){
            var SELF = \(escapedSelf);
            var main = document.querySelector('#main');
            if (!main) return '[]';
            var rows = main.querySelectorAll('[role="row"]');
            var out = [];
            var carried = null;   // direction of the last row we could place
            for (var i = 0; i < rows.length; i++) {
                var row = rows[i];
                var rowText = row.textContent || '';
                var dir = null;

                var pre = row.querySelector('[data-pre-plain-text]');
                var ts = '';
                if (pre) {
                    var m = (pre.getAttribute('data-pre-plain-text') || '')
                        .match(/^\\[([^\\]]+)\\]\\s*(.+?):\\s*$/);
                    if (m) {
                        ts = m[1];
                        var sender = m[2].trim();
                        dir = (sender === SELF || sender.indexOf(SELF) === 0) ? 'out' : 'in';
                    }
                }
                if (dir === null) {
                    if (/tail-out/.test(rowText)) dir = 'out';
                    else if (/tail-in/.test(rowText)) dir = 'in';
                }
                if (dir === null) dir = carried;   // same run as the row above
                if (dir !== null) carried = dir;
                if (dir === null) continue;

                var sel = row.querySelector('.selectable-text');
                if (!sel) continue;
                var txt = (sel.textContent || '')
                    .replace(/\\s*\\d{1,2}:\\d{2}\\s*[ap]m\\s*$/i, '')
                    .trim();
                if (txt) out.push([dir, ts, txt]);
            }
            return JSON.stringify(out);
        })()
        """
        guard let json = c.eval(js),
              let data = json.data(using: .utf8),
              let rows = try? JSONDecoder().decode([[String]].self, from: data) else { return [] }
        return rows.compactMap { r in
            r.count == 3 ? WAMessage(outgoing: r[0] == "out", at: parseStamp(r[1]), text: r[2]) : nil
        }
    }

    /// WhatsApp's `data-pre-plain-text` stamp, e.g. "2:46 pm, 10/11/2026".
    /// ponytail: day-first dates and 12h/24h clocks only (what an Indian-locale
    /// WhatsApp Web writes); a US-locale M/d stamp will misparse or return nil,
    /// which only costs the idle cutoff for that message.
    static func parseStamp(_ s: String) -> Date? {
        let t = s.trimmingCharacters(in: .whitespaces)
        for fmt in stampFormatters { if let d = fmt.date(from: t) { return d } }
        return nil
    }

    /// Built once: this runs per bubble, inside a retry loop.
    private static let stampFormatters: [DateFormatter] = ["h:mm a, d/M/yyyy", "HH:mm, d/M/yyyy"].map {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = $0
        return fmt
    }

    /// Block until the open conversation has actually rendered its messages.
    ///
    /// The message pane is virtualised and populates after the click settles;
    /// querying too early returns zero rows, which `readMessages` cannot tell
    /// apart from "nothing to read". A real chat measured zero rows at the 0.6s
    /// the engine used to allow.
    @discardableResult
    static func waitForMessages(timeout: TimeInterval = 4) -> Bool {
        guard let c = ensureCDP() else { return false }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let n = c.eval("(function(){var m=document.querySelector('#main');return m ? String(m.querySelectorAll('[role=\"row\"]').length) : '0';})()")
            if let n = n, let count = Int(n), count > 0 { return true }
            Thread.sleep(forTimeInterval: 0.3)
        }
        return false
    }

    /// Snapshot of every visible chat row's preview text, NOT just unread
    /// ones — used by `WhatsAppActivityLogger` to build a running picture of
    /// the day's chats (including ones already read on the phone) for the
    /// daily summary.
    static func allChatsPreview(limit: Int = 60) -> [WAChatPreview] {
        guard let c = ensureCDP() else { return [] }
        let js = """
        (function(){
            // Only the sidebar: `[role="row"]` page-wide also matched the
            // open chat's message bubbles, which logged "1:36 pm" as a chat
            // name and SVG icon names as text. Name and preview come from the
            // same elements `unreadChats` reads; group rows keep their sender.
            var TICK = /^(wds-ic-)?(read|delivered|sent|pending|msg-check|msg-dblcheck|msg-time|status-check|status-dblcheck|status-time)$/;
            var BIDI = /[\\u202A-\\u202E\\u200E\\u200F\\u2066-\\u2069]/g;
            var result = [];
            var rows = document.querySelectorAll('#pane-side [role="row"]');
            for (var i = 0; i < rows.length && result.length < \(limit); i++) {
                var status = rows[i].querySelector('[data-testid="last-msg-status"]');
                var nameEl = rows[i].querySelector('span[title]:not([data-testid="last-msg-status"])');
                var name = nameEl ? (nameEl.getAttribute('title') || '').replace(BIDI, '').trim() : '';
                var preview = status ? (status.getAttribute('title') || '').replace(BIDI, '').trim() : '';
                if (!name || !preview || name === 'Message yourself') continue;
                var sender = '';
                for (var k = 0; k < status.children.length; k++) {
                    if ((status.children[k].textContent || '').trim() === ':') {
                        var auto = status.querySelector('span[dir="auto"]');
                        if (auto) sender = (auto.textContent || '').replace(BIDI, '').trim();
                        break;
                    }
                }
                // The preview never names you: your own last message is marked only
                // by its sent/delivered/read tick. Without this, everything you sent
                // in a 1:1 chat read as the other person writing to you.
                if (!sender) {
                    var marks = status.querySelectorAll('svg title, [data-icon]');
                    for (var m = 0; m < marks.length; m++) {
                        var icon = marks[m].getAttribute('data-icon') || marks[m].textContent || '';
                        if (TICK.test(icon)) { sender = 'You'; break; }
                    }
                }
                result.push({name: name, preview: (sender ? sender + ': ' : '') + preview.substring(0, 300)});
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
        Thread.sleep(forTimeInterval: 1.0)   // the list measured ~1s to render
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
            // A call row's visible text is [name, time, "Incoming"/"Outgoing"/
            // "Missed" (+ " (2)")]; voice vs video is only in the icon's SVG
            // title, which is why text inside <svg> is skipped and read apart.
            // ponytail: English labels only; a localised WhatsApp logs no calls.
            var result = [];
            var rows = document.querySelectorAll('#pane-side [role="row"]');
            for (var i = 0; i < rows.length && result.length < \(limit); i++) {
                var w = document.createTreeWalker(rows[i], NodeFilter.SHOW_TEXT), n, t = [];
                while ((n = w.nextNode())) {
                    var s = n.parentElement.closest('svg') ? '' : n.textContent.trim();
                    if (s) t.push(s);
                }
                if (t.length < 3 || !/^(missed|incoming|outgoing)/i.test(t[t.length - 1])) continue;
                var icons = Array.from(rows[i].querySelectorAll('svg title')).map(function(x){ return x.textContent; }).join(' ');
                result.push({name: t[0], info: t[t.length - 1] + (/video/i.test(icons) ? ' video call' : ' voice call'), timeText: t[1]});
            }
            return JSON.stringify(result);
        })()
        """
        guard let json = c.eval(js),
              let data = json.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([WACall].self, from: data)) ?? []
    }

    /// Type a reply into the open conversation and leave it there unsent.
    /// WhatsApp keeps a per-chat draft, so the bot can draft into several chats
    /// in a row and each one holds its own text until the user looks.
    static func draftMessage(_ text: String) -> Bool {
        sendMessage(text, send: false)
    }

    /// Send a reply to the open conversation. Returns false if the chat has
    /// no reply input (read-only business/broadcast/channel chats expose no
    /// contenteditable footer — bot must skip them, not retry).
    ///
    /// `send: false` stops after typing, which is what draft-only mode wants.
    static func sendMessage(_ text: String, send: Bool = true) -> Bool {
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
        guard send else {
            cblog("CDP: drafted (not sent)")
            return true
        }
        c.pressEnter()
        return true
    }

    /// Bring the bot's browser to the front, so the user can look at a draft
    /// the bot left in a chat. Not used by the reply path itself — that runs
    /// entirely over CDP and never needs focus.
    static func activate() {
        guard let b = ChromeBot.availableBrowser() else { return }
        // .../X.app/Contents/MacOS/X -> .../X.app
        let bundle = URL(fileURLWithPath: b.path)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        NSWorkspace.shared.open(bundle)
    }
}
