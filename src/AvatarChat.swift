import Cocoa
import WebKit
import AVFoundation

/// The small box a single click on the avatar opens: ask about your last two weeks of meetings, days, notes and
/// projects. Clicking the avatar again or Esc closes it, and forgets the conversation. Same page and behaviour as
/// windows/src/renderer/avatarChat.html; the mic records natively, as in EditChat.
final class AvatarChat: NSObject, NSWindowDelegate, WKScriptMessageHandler {
    private static var current: AvatarChat?
    // Held here: transcribe() bails out quietly if its Transcriber is gone.
    private static let transcriber = Transcriber()

    static func toggle(near avatar: NSRect, agent: MOMGenerator, recording: @escaping () -> Bool) {
        if let c = current { c.window.close(); return }
        let c = AvatarChat(agent: agent, recording: recording)
        current = c
        c.place(near: avatar)
        c.window.makeKeyAndOrderFront(nil)
    }

    /// Borderless panels can't take the keyboard unless they say so.
    private final class KeyPanel: NSPanel { override var canBecomeKey: Bool { true } }

    private let window: NSPanel
    private let web: WKWebView
    private let agent: MOMGenerator
    private let recording: () -> Bool
    private var history: [(q: String, a: String)] = []
    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private let voiceURL = URL(fileURLWithPath: NSHomeDirectory() + "/.nikxel/edits/chat-voice.wav")

    private init(agent: MOMGenerator, recording: @escaping () -> Bool) {
        self.agent = agent
        self.recording = recording
        window = KeyPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 280),
                          styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        let config = WKWebViewConfiguration()
        config.userContentController.addUserScript(WKUserScript(
            source: "var startRecording = \(recording());", injectionTime: .atDocumentStart, forMainFrameOnly: true))
        web = WKWebView(frame: .zero, configuration: config)
        super.init()
        config.userContentController.add(self, name: "nx")

        window.level = .floating
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true
        window.hidesOnDeactivate = false  // clicking elsewhere leaves it up
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.delegate = self

        let fx = NSVisualEffectView()
        fx.material = .hudWindow
        fx.blendingMode = .behindWindow
        fx.state = .active
        let r: CGFloat = 16
        let mask = NSImage(size: NSSize(width: 2 * r + 1, height: 2 * r + 1), flipped: false) { rect in
            NSBezierPath(roundedRect: rect, xRadius: r, yRadius: r).fill(); return true
        }
        mask.capInsets = NSEdgeInsets(top: r, left: r, bottom: r, right: r)
        mask.resizingMode = .stretch
        fx.maskImage = mask
        web.setValue(false, forKey: "drawsBackground")
        web.autoresizingMask = [.width, .height]
        window.contentView = fx
        web.frame = fx.bounds
        fx.addSubview(web)
        web.loadHTMLString(AvatarChat.page, baseURL: nil)

        // A recording can start or stop while the box is open; the mic follows it.
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.web.evaluateJavaScript("setRecording(\(self.recording()))")
        }
    }

    /// Beside the avatar on the side with room, level with it, kept on screen.
    private func place(near avatar: NSRect) {
        let scr = NSScreen.screens.first { $0.frame.intersects(avatar) } ?? NSScreen.main ?? NSScreen.screens[0]
        let v = scr.visibleFrame, s = window.frame.size, gap: CGFloat = 8
        let x = avatar.maxX + gap + s.width <= v.maxX ? avatar.maxX + gap : avatar.minX - gap - s.width
        let y = min(max(avatar.midY - s.height / 2, v.minY), v.maxY - s.height)
        window.setFrameOrigin(NSPoint(x: x, y: y))
    }

    func windowWillClose(_ notification: Notification) {
        timer?.invalidate(); timer = nil
        recorder?.stop(); recorder = nil
        web.configuration.userContentController.removeScriptMessageHandler(forName: "nx")
        if AvatarChat.current === self { AvatarChat.current = nil }
    }

    /// The page asks with {type, id, text}; the answer goes back to nx.resolve(id, value).
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        let id = body["id"] as? Int ?? 0
        let text = body["text"] as? String ?? ""
        switch type {
        case "close":
            window.close()
        case "send":
            let history = self.history, agent = self.agent, today = Date()
            DispatchQueue.global(qos: .userInitiated).async {
                let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/nikxel")
                let (feed, offline) = CloudSync.projectFeed()
                let context = ChatContext.build(ChatContext.localBlocks(root: root, today: today) + ChatContext.projectBlocks(feed),
                                                cap: ChatContext.cap)
                var answer: String?
                let reply: String
                do {
                    let a = try agent.runPrompt(ChatContext.prompt(context: context, history: history, question: text, today: today),
                                                kind: "chat", claudeModel: "haiku", timeout: 30)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    answer = a; reply = a
                } catch MOMGenerator.MOMError.agentNotFound {
                    reply = "Connect Claude in Settings to use chat."
                } catch {
                    reply = "⚠︎ \(error)"
                }
                cblog("AvatarChat: \(context.count) chars of context, \(answer == nil ? "failed" : "answered")")
                DispatchQueue.main.async {
                    if let a = answer { self.history.append((q: text, a: a)) }
                    self.resolve(id, ["text": reply, "offline": offline])
                }
            }
        case "mic":
            if let r = recorder {
                r.stop(); recorder = nil
                AvatarChat.transcriber.transcribe(audioURL: voiceURL, outputFormat: .txt) { result in
                    let heard = (try? result.get()).flatMap { try? String(contentsOf: $0, encoding: .utf8) }?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    DispatchQueue.main.async { self.resolve(id, heard) }
                }
                return
            }
            // The meeting recorder has the mic; typing still works.
            if recording() { resolve(id, "busy"); return }
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

    private func resolve(_ id: Int, _ value: Any) {
        let json = (try? JSONSerialization.data(withJSONObject: [value])).flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
        web.evaluateJavaScript("nx.resolve(\(id), \(json)[0])")
    }

    /// Same markup and CSS as windows/src/renderer/avatarChat.html, except the glass: here the
    /// page is clear over an NSVisualEffectView; Electron can't blur, so Windows tints instead.
    private static let page = #"""
<!doctype html><html><head><meta charset="utf-8">
<style>
:root{--glass:transparent;--fg:#1d1d1f;--muted:#6e6e73;--bot:rgba(255,255,255,.72);--line:rgba(0,0,0,.09);--me:#1d1d1f;--me-fg:#fff;--accent:#5e5ce6;--field:rgba(255,255,255,.8);color-scheme:light dark}
@media (prefers-color-scheme:dark){:root{--fg:#f5f5f7;--muted:#a1a1a6;--bot:rgba(255,255,255,.09);--line:rgba(255,255,255,.1);--me:#f5f5f7;--me-fg:#1d1d1f;--field:rgba(255,255,255,.08)}}
*{box-sizing:border-box}
html,body{height:100%;margin:0;background:transparent;overflow:hidden}
body{display:flex;flex-direction:column;background:var(--glass);border-radius:16px;color:var(--fg);font:13px/1.42 system-ui,-apple-system,"Segoe UI",sans-serif;-webkit-user-select:none;user-select:none}
header{display:flex;align-items:center;gap:8px;padding:10px 10px 6px 14px}
header b{font-size:12px;letter-spacing:.01em}
#offline{display:none;color:var(--muted);font-size:11px;padding:1px 7px;border:1px solid var(--line);border-radius:999px}
#offline.on{display:inline-block}
.sp{flex:1}
#close{width:22px;height:22px;border-radius:50%;border:0;background:transparent;color:var(--muted);font:15px/1 system-ui;cursor:pointer}
#close:hover{background:var(--line)}
#log{flex:1;overflow-y:auto;padding:4px 12px 6px;display:flex;flex-direction:column;gap:8px}
.msg{max-width:88%;padding:7px 11px;border-radius:15px;white-space:pre-wrap;-webkit-user-select:text;user-select:text;animation:in .2s ease-out}
.bot{align-self:flex-start;background:var(--bot);border:1px solid var(--line);border-bottom-left-radius:5px}
.me{align-self:flex-end;background:var(--me);color:var(--me-fg);border-bottom-right-radius:5px}
.hello{color:var(--muted);background:transparent;border-color:transparent;padding-left:2px}
.dots{display:inline-flex;gap:4px;padding:3px 0}
.dots i{width:6px;height:6px;border-radius:50%;background:var(--muted);animation:bob 1.1s infinite}
.dots i:nth-child(2){animation-delay:.15s}.dots i:nth-child(3){animation-delay:.3s}
.hint{color:var(--muted);font-size:11.5px;margin-left:6px}
@keyframes bob{0%,70%,100%{opacity:.3;transform:translateY(0)}35%{opacity:1;transform:translateY(-3px)}}
@keyframes in{from{opacity:0;transform:translateY(5px)}}
form{display:flex;align-items:center;gap:2px;margin:4px 10px 10px;padding:3px 3px 3px 13px;border:1px solid var(--line);border-radius:999px;background:var(--field);transition:border-color .15s}
form:focus-within{border-color:var(--accent)}
input{flex:1;min-width:0;border:0;outline:0;background:transparent;color:var(--fg);font:inherit;padding:6px 0}
.icon{width:30px;height:30px;border-radius:50%;border:0;display:grid;place-items:center;cursor:pointer;background:transparent;color:var(--muted);transition:background .15s,opacity .15s;flex:none}
.icon:hover:not(:disabled){background:var(--line)}
.icon:disabled{opacity:.35;cursor:default}
.icon svg{width:15px;height:15px}
#send{background:var(--accent);color:#fff}
#send:hover:not(:disabled){filter:brightness(1.1)}
#mic.rec{background:#ff3b30;color:#fff;animation:pulse 1.3s infinite}
@keyframes pulse{0%{box-shadow:0 0 0 0 rgba(255,59,48,.55)}100%{box-shadow:0 0 0 10px rgba(255,59,48,0)}}
</style></head><body>
<header><b>Ask Nikxel</b><span id="offline">projects offline</span><span class="sp"></span><button id="close" title="Close (Esc)">×</button></header>
<div id="log"></div>
<form id="f"><input id="input" placeholder="Ask about your meetings, days, projects…" autocomplete="off">
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
  close: function () { webkit.messageHandlers.nx.postMessage({ type: "close" }); },
  micStart: function () { return ask("mic").then(function (r) { return r === "recording"; }); },
  micStop: function () { return ask("mic"); }
};
</script>
<script>
// Shared with windows/src/renderer/avatarChat.ts: everything below uses only `api`.
var log = document.getElementById("log"), input = document.getElementById("input");
var mic = document.getElementById("mic"), send = document.getElementById("send");
var busy = false, listening = false, meeting = false;
function sync() {
  input.disabled = busy || listening;
  mic.disabled = busy || (meeting && !listening);  // a listen already running can still be stopped
  mic.title = meeting ? "Recording — type instead" : "Tap, speak, tap again to send";
  send.disabled = busy || listening || !input.value.trim();
}
function setRecording(on) { if (on !== meeting) { meeting = on; sync(); } }
function bubble(cls, text) {
  var d = document.createElement("div"); d.className = "msg " + cls; d.textContent = text;
  log.appendChild(d); log.scrollTop = log.scrollHeight; return d;
}
function typing(label) {
  var d = bubble("bot", ""); d.innerHTML = '<span class="dots"><i></i><i></i><i></i></span>';
  var s = document.createElement("span"); s.className = "hint"; s.textContent = label; d.appendChild(s);
  return d;
}
function settle(d, text) { d.textContent = text; log.scrollTop = log.scrollHeight; }
function run(text) {
  bubble("me", text);
  var w = typing("thinking…"); busy = true; sync();
  api.send(text).then(function (r) {
    settle(w, r.text); document.getElementById("offline").classList.toggle("on", !!r.offline);
    busy = false; sync(); input.focus();
  });
}
document.getElementById("f").onsubmit = function (e) {
  e.preventDefault(); var t = input.value.trim(); if (!t || busy) return;
  input.value = ""; run(t);
};
input.oninput = sync;
document.getElementById("close").onclick = function () { api.close(); };
document.addEventListener("keydown", function (e) { if (e.key === "Escape") api.close(); });
mic.onclick = function () {
  if (!listening) {
    api.micStart().then(function (ok) {
      if (!ok) { bubble("bot", "Couldn't use the microphone."); return; }
      listening = true; mic.classList.add("rec"); input.placeholder = "Listening… tap the mic to send"; sync();
    });
    return;
  }
  listening = false; mic.classList.remove("rec"); input.placeholder = "Ask about your meetings, days, projects…";
  var w = typing("Listening back…"); busy = true; sync();
  api.micStop().then(function (text) {
    busy = false; sync();
    if (!text) { settle(w, "Didn't catch that."); return; }
    log.removeChild(w); run(text);
  });
};
bubble("bot hello", "Ask me anything from the last two weeks.");
setRecording(typeof startRecording !== "undefined" && startRecording);
sync(); input.focus();
</script></body></html>
"""#
}
