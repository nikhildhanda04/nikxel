import AppKit
import AVFoundation
import WebKit

/// Edits a finished summary from a sentence: "Speaker 3 is Rahul", "merge the
/// 2nd and 4th action items". The agent gets the summary's Markdown, the
/// meeting transcript and the instruction, and hands back the whole updated
/// Markdown, which replaces the .md and re-renders the page beside it.
///
/// Meeting and notes pages, for everyone. Daily and weekly summaries only in a
/// build with a private/ folder (see build.sh) -- that code isn't on GitHub.
enum PageEdit {
    private static let root = URL(fileURLWithPath: NSHomeDirectory() + "/Documents/nikxel").resolvingSymlinksInPath()
    private static let backups = URL(fileURLWithPath: NSHomeDirectory() + "/.nikxel/edits")
    private static let agent = MOMGenerator()

    static var daysEditable: Bool {
        #if NIKXEL_PRIVATE
        return true
        #else
        return false
        #endif
    }

    static func editable(_ page: URL) -> Bool {
        switch page.deletingLastPathComponent().resolvingSymlinksInPath().path {
        case root.appendingPathComponent("meetings").path, root.appendingPathComponent("notes").path: return true
        case root.appendingPathComponent("daily").path, root.appendingPathComponent("weekly").path: return daysEditable
        default: return false
        }
    }

    /// Runs the instruction against `page`'s summary. Returns the agent's
    /// one-line note on what changed. Slow (an agent run): call off main.
    static func apply(_ instruction: String, to page: URL) throws -> String {
        let md = page.deletingPathExtension().appendingPathExtension("md")
        let transcriptURL = page.deletingPathExtension().appendingPathExtension("transcript.txt")
        guard editable(page), let current = try? String(contentsOf: md, encoding: .utf8) else {
            throw edit("This summary can't be edited.")
        }
        let transcript = (try? String(contentsOf: transcriptURL, encoding: .utf8)) ?? ""
        let out = try agent.runPrompt(prompt(instruction, current, transcript), kind: "summary-edit", claudeModel: "sonnet")
        guard let split = out.range(of: "\n---\n") else { throw edit("The agent's reply wasn't a summary. Nothing changed.") }
        let head = out[..<split.lowerBound], updated = String(out[split.upperBound...])
            .trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
        guard updated.hasPrefix("# ") else { throw edit("The agent's reply wasn't a summary. Nothing changed.") }

        var note = "Updated.", renames: [(String, String)] = []
        for line in head.split(separator: "\n") {
            if line.hasPrefix("NOTE:") { note = line.dropFirst(5).trimmingCharacters(in: .whitespaces) }
            if line.hasPrefix("RENAME:") {
                let parts = line.dropFirst(7).components(separatedBy: "=>").map { $0.trimmingCharacters(in: .whitespaces) }
                if parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty { renames.append((parts[0], parts[1])) }
            }
        }
        guard updated != current else { return note }

        // Every edit keeps what it replaced, so Undo can step back one at a time.
        let dir = backups.appendingPathComponent(md.deletingPathExtension().lastPathComponent)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stamp = String(Int(Date().timeIntervalSince1970 * 1000))
        try current.write(to: dir.appendingPathComponent("\(stamp).md"), atomically: true, encoding: .utf8)
        if !renames.isEmpty, !transcript.isEmpty {
            // Renamed speakers stick in the transcript too, so a regenerate keeps them.
            try transcript.write(to: dir.appendingPathComponent("\(stamp).transcript.txt"), atomically: true, encoding: .utf8)
            let renamed = renames.reduce(transcript) { $0.replacingOccurrences(of: $1.0, with: $1.1) }
            try renamed.write(to: transcriptURL, atomically: true, encoding: .utf8)
        }
        try save(updated, md: md, page: page)
        return note
    }

    /// Puts back the version before the last edit. False when there's none.
    static func undo(_ page: URL) throws -> Bool {
        let md = page.deletingPathExtension().appendingPathExtension("md")
        let dir = backups.appendingPathComponent(md.deletingPathExtension().lastPathComponent)
        let versions = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { $0.hasSuffix(".md") }.sorted()
        guard let last = versions.last else { return false }
        let prev = dir.appendingPathComponent(last)
        try save(try String(contentsOf: prev, encoding: .utf8), md: md, page: page)
        let transcript = dir.appendingPathComponent(last.replacingOccurrences(of: ".md", with: ".transcript.txt"))
        if FileManager.default.fileExists(atPath: transcript.path) {
            _ = try? FileManager.default.replaceItemAt(page.deletingPathExtension().appendingPathExtension("transcript.txt"), withItemAt: transcript)
        }
        try FileManager.default.removeItem(at: prev)
        return true
    }

    private static func save(_ markdown: String, md: URL, page: URL) throws {
        try markdown.write(to: md, atomically: true, encoding: .utf8)
        #if NIKXEL_PRIVATE
        if let html = PrivateEdits.page(markdown: markdown, md: md) {
            try html.write(to: page, atomically: true, encoding: .utf8); return
        }
        #endif
        try NotePage.html(from: markdown).write(to: page, atomically: true, encoding: .utf8)
    }

    private static func edit(_ s: String) -> NSError {
        NSError(domain: "Nikxel", code: 1, userInfo: [NSLocalizedDescriptionKey: s])
    }

    private static func prompt(_ instruction: String, _ summary: String, _ transcript: String) -> String {
        """
        You are editing a summary Nikxel already wrote. Apply the user's instruction to the Markdown below and change nothing else: keep every heading, the section order and the formatting conventions exactly as they are. If the instruction renames a speaker, rename them everywhere in the summary.

        Instruction: \(instruction)

        Reply in exactly this form and nothing else:
        NOTE: <one short sentence on what you changed, or why you couldn't>
        RENAME: <speaker label as written> => <new name>   (one line per renamed speaker; leave out if none)
        ---
        <the full updated Markdown, starting with its "# " title line>

        If you can't apply the instruction, give the NOTE and the Markdown unchanged.

        ===== SUMMARY (Markdown) =====
        \(summary)
        \(transcript.isEmpty ? "" : "\n===== TRANSCRIPT (for reference only; do not output it) =====\n\(transcript.prefix(120_000))")
        """
    }
}


/// The small chat window behind a page's Edit button. One per page; type or
/// tap the mic and say it. A web view, so it looks like the pages it edits and
/// shares its look with the Windows window (renderer/editChat.html).
final class EditChat: NSObject, NSWindowDelegate, WKScriptMessageHandler {
    private static var open: [URL: EditChat] = [:]
    // Held here: transcribe() bails out quietly if its Transcriber is gone.
    private static let transcriber = Transcriber()

    static func show(_ page: URL) {
        let chat = open[page] ?? EditChat(page)
        open[page] = chat
        NSApp.activate(ignoringOtherApps: true)
        chat.window.makeKeyAndOrderFront(nil)
    }

    private let page: URL
    private let window: NSPanel
    private let web: WKWebView
    private var recorder: AVAudioRecorder?
    private let voiceURL = URL(fileURLWithPath: NSHomeDirectory() + "/.nikxel/edits/voice.wav")

    private init(_ page: URL) {
        self.page = page
        window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 540),
                         styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        let config = WKWebViewConfiguration()
        web = WKWebView(frame: .zero, configuration: config)
        super.init()
        config.userContentController.add(self, name: "nx")

        let title = (try? String(contentsOf: page.deletingPathExtension().appendingPathExtension("md"), encoding: .utf8))?
            .split(separator: "\n").first.map { $0.replacingOccurrences(of: "# ", with: "") } ?? page.lastPathComponent
        window.title = "Edit · \(title)"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        // The title bar is the drag strip; tinted to match the page below it.
        window.backgroundColor = NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.11, green: 0.11, blue: 0.118, alpha: 1) : NSColor(srgbRed: 0.969, green: 0.969, blue: 0.976, alpha: 1) }
        window.minSize = NSSize(width: 320, height: 380)
        window.level = .floating
        window.hidesOnDeactivate = false  // stays up beside the page while you read it
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = web
        window.center()

        let icon = NoteExporter.favicon.components(separatedBy: "href=\"").last?.components(separatedBy: "\"").first ?? ""
        let html = EditChat.page
            .replacingOccurrences(of: "__TITLE__", with: NoteExporter.escape(title))
            .replacingOccurrences(of: "__ICON__", with: icon)
        web.loadHTMLString(html, baseURL: nil)
    }

    func windowWillClose(_ notification: Notification) {
        recorder?.stop(); recorder = nil
        web.configuration.userContentController.removeScriptMessageHandler(forName: "nx")
        EditChat.open[page] = nil
    }

    /// The page asks with {type, id, text}; the answer goes back to nx.resolve(id, text).
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String,
              let id = body["id"] as? Int else { return }
        let text = body["text"] as? String ?? ""
        let page = self.page
        switch type {
        case "send":
            DispatchQueue.global(qos: .userInitiated).async {
                let reply: String
                do { reply = try PageEdit.apply(text, to: page) } catch { reply = "⚠︎ " + error.localizedDescription }
                cblog("PageEdit: \(page.lastPathComponent) — \(reply)")
                DispatchQueue.main.async { self.resolve(id, reply) }
            }
        case "undo":
            let ok = (try? PageEdit.undo(page)) ?? false
            resolve(id, ok ? "Undone — the page is back to how it was before the last change." : "Nothing to undo.")
        case "mic":
            if let r = recorder {
                r.stop(); recorder = nil
                EditChat.transcriber.transcribe(audioURL: voiceURL, outputFormat: .txt) { result in
                    let heard = (try? result.get()).flatMap { try? String(contentsOf: $0, encoding: .utf8) }?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    DispatchQueue.main.async { self.resolve(id, heard) }
                }
                return
            }
            try? FileManager.default.createDirectory(at: voiceURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16000,
                                           AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16]
            if let r = try? AVAudioRecorder(url: voiceURL, settings: settings), r.record() {
                recorder = r; resolve(id, "recording")
            } else {
                resolve(id, "")
            }
        default:
            break
        }
    }

    private func resolve(_ id: Int, _ text: String) {
        let json = (try? JSONSerialization.data(withJSONObject: [text])).flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
        web.evaluateJavaScript("nx.resolve(\(id), \(json)[0])")
    }

    /// Same markup and CSS as windows/src/renderer/editChat.html; only the
    /// bridge (webkit.messageHandlers) and the mic (recorded natively) differ.
    private static let page = #"""
<!doctype html><html><head><meta charset="utf-8">
<style>
:root{--bg:#f7f7f9;--fg:#1d1d1f;--muted:#6e6e73;--bot:#fff;--line:#e3e3e8;--me:#1d1d1f;--me-fg:#fff;--accent:#5e5ce6;--field:#fff;color-scheme:light dark}
@media (prefers-color-scheme:dark){:root{--bg:#1c1c1e;--fg:#f5f5f7;--muted:#98989d;--bot:#2c2c2e;--line:#38383a;--me:#f5f5f7;--me-fg:#1d1d1f;--field:#2c2c2e}}
*{box-sizing:border-box}
html,body{height:100%;margin:0}
body{display:flex;flex-direction:column;background:var(--bg);color:var(--fg);font:13.5px/1.45 system-ui,-apple-system,"Segoe UI",sans-serif;-webkit-user-select:none;user-select:none}
header{display:flex;align-items:center;gap:10px;padding:12px 14px;border-bottom:1px solid var(--line)}
.mark{width:34px;height:34px;border-radius:10px;background:linear-gradient(135deg,#5e5ce6,#bf5af2);display:grid;place-items:center;flex:none;box-shadow:0 2px 8px rgba(94,92,230,.35)}
.mark img{width:26px;height:26px;image-rendering:pixelated}
.hd{flex:1;min-width:0}
.hd b{display:block;font-size:13.5px}
.hd span{display:block;color:var(--muted);font-size:11.5px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.ghost{border:1px solid var(--line);background:var(--field);color:var(--fg);border-radius:999px;padding:5px 12px;font:inherit;font-size:12px;cursor:pointer;transition:background .15s}
.ghost:hover:not(:disabled){background:var(--line)}
.ghost:disabled{opacity:.45;cursor:default}
#log{flex:1;overflow-y:auto;padding:16px 14px 8px;display:flex;flex-direction:column;gap:10px}
.msg{max-width:85%;padding:9px 13px;border-radius:18px;white-space:pre-wrap;-webkit-user-select:text;user-select:text;animation:in .2s ease-out}
.bot{align-self:flex-start;background:var(--bot);border:1px solid var(--line);border-bottom-left-radius:6px}
.me{align-self:flex-end;background:var(--me);color:var(--me-fg);border-bottom-right-radius:6px}
.done{border-color:rgba(48,209,88,.45)}
.chips{display:flex;flex-wrap:wrap;gap:6px;margin-top:2px}
.dots{display:inline-flex;gap:4px;padding:4px 0}
.dots i{width:7px;height:7px;border-radius:50%;background:var(--muted);animation:bob 1.1s infinite}
.dots i:nth-child(2){animation-delay:.15s}.dots i:nth-child(3){animation-delay:.3s}
.hint{color:var(--muted);font-size:12px;margin-left:6px}
@keyframes bob{0%,70%,100%{opacity:.3;transform:translateY(0)}35%{opacity:1;transform:translateY(-3px)}}
@keyframes in{from{opacity:0;transform:translateY(6px)}}
form{display:flex;align-items:center;gap:4px;margin:6px 12px 12px;padding:4px 4px 4px 16px;border:1px solid var(--line);border-radius:999px;background:var(--field);box-shadow:0 4px 18px rgba(0,0,0,.07);transition:border-color .15s}
form:focus-within{border-color:var(--accent)}
input{flex:1;min-width:0;border:0;outline:0;background:transparent;color:var(--fg);font:inherit;padding:7px 0}
.icon{width:34px;height:34px;border-radius:50%;border:0;display:grid;place-items:center;cursor:pointer;background:transparent;color:var(--muted);transition:background .15s,opacity .15s;flex:none}
.icon:hover:not(:disabled){background:var(--line)}
.icon:disabled{opacity:.35;cursor:default}
.icon svg{width:17px;height:17px}
#send{background:var(--accent);color:#fff}
#send:hover:not(:disabled){background:var(--accent);filter:brightness(1.1)}
#mic.rec{background:#ff3b30;color:#fff;animation:pulse 1.3s infinite}
@keyframes pulse{0%{box-shadow:0 0 0 0 rgba(255,59,48,.55)}100%{box-shadow:0 0 0 12px rgba(255,59,48,0)}}
</style></head><body>
<header><div class="mark"><img src="__ICON__" alt=""></div><div class="hd"><b>Edit summary</b><span>__TITLE__</span></div><button class="ghost" id="undo" title="Put back the version before the last change">↺ Undo</button></header>
<div id="log"></div>
<form id="f"><input id="input" placeholder="Tell Nikxel what to change…" autocomplete="off">
<button type="button" class="icon" id="mic" title="Tap, speak, tap again to send"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="9" y="2" width="6" height="12" rx="3"/><path d="M5 10a7 7 0 0 0 14 0M12 17v5"/></svg></button>
<button class="icon" id="send" title="Send"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round"><path d="M12 19V5M5 12l7-7 7 7"/></svg></button></form>
<script>
var pending = {}, seq = 0;
window.nx = { resolve: function (id, v) { var f = pending[id]; delete pending[id]; if (f) f(v); } };
function ask(type, text) {
  return new Promise(function (r) { var id = ++seq; pending[id] = r; webkit.messageHandlers.nx.postMessage({ type: type, id: id, text: text || "" }); });
}
var api = {
  send: function (t) { return ask("send", t); },
  undo: function () { return ask("undo"); },
  micStart: function () { return ask("mic").then(function (r) { return r === "recording"; }); },
  micStop: function () { return ask("mic"); }
};
</script>
<script>
// Shared with windows/src/renderer/editChat.ts: everything below uses only `api`.
var log = document.getElementById("log"), input = document.getElementById("input");
var mic = document.getElementById("mic"), send = document.getElementById("send"), undoBtn = document.getElementById("undo");
var busy = false, recording = false;
function sync() {
  input.disabled = busy || recording; undoBtn.disabled = busy || recording;
  mic.disabled = busy; send.disabled = busy || recording || !input.value.trim();
}
function bubble(cls, text) {
  var d = document.createElement("div"); d.className = "msg " + cls; d.textContent = text;
  log.appendChild(d); log.scrollTop = log.scrollHeight; return d;
}
function typing(label) {
  var d = bubble("bot", ""); d.innerHTML = '<span class="dots"><i></i><i></i><i></i></span>';
  if (label) { var s = document.createElement("span"); s.className = "hint"; s.textContent = label; d.appendChild(s); }
  return d;
}
function settle(d, text, ok) { d.textContent = text; if (ok) d.classList.add("done"); log.scrollTop = log.scrollHeight; }
function run(text) {
  bubble("me", text);
  var w = typing("Rewriting the summary…"); busy = true; sync();
  api.send(text).then(function (reply) {
    settle(w, reply, reply.indexOf("⚠") !== 0); busy = false; sync(); input.focus();
  });
}
document.getElementById("f").onsubmit = function (e) {
  e.preventDefault(); var t = input.value.trim(); if (!t || busy) return;
  input.value = ""; run(t);
};
input.oninput = sync;
undoBtn.onclick = function () { api.undo().then(function (r) { bubble("bot", r); }); };
mic.onclick = function () {
  if (!recording) {
    api.micStart().then(function (ok) {
      if (!ok) { bubble("bot", "Couldn't use the microphone."); return; }
      recording = true; mic.classList.add("rec"); input.placeholder = "Listening… tap the mic to send"; sync();
    });
    return;
  }
  recording = false; mic.classList.remove("rec"); input.placeholder = "Tell Nikxel what to change…";
  var w = typing("Listening back…"); busy = true; sync();
  api.micStop().then(function (text) {
    busy = false; sync();
    if (!text) { settle(w, "I didn't catch that — try again or type it."); return; }
    log.removeChild(w); run(text);
  });
};
var hello = bubble("bot", "Hi! Tell me what to change in this summary. Every change can be undone.");
var chips = document.createElement("div"); chips.className = "chips";
[["Rename a speaker", "Speaker 1 is "], ["Merge two tasks", "Merge action items 1 and 2"], ["Make it shorter", "Make the summary shorter"]].forEach(function (c) {
  var b = document.createElement("button"); b.className = "ghost"; b.type = "button"; b.textContent = c[0];
  b.onclick = function () { input.value = c[1]; input.focus(); sync(); };
  chips.appendChild(b);
});
hello.appendChild(chips);
sync(); input.focus();
</script></body></html>
"""#
}
