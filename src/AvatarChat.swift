import Cocoa
import WebKit
import AVFoundation

/// The chat a single click on the avatar opens: no panel, just bubbles and a field floating beside it.
/// Ask about your last two weeks of meetings, days, notes and projects. Clicking the avatar again or Esc closes it, and forgets the conversation. Same page and behaviour as
/// windows/src/renderer/avatarChat.html; the mic records natively, as in EditChat.
final class AvatarChat: NSObject, NSWindowDelegate, WKScriptMessageHandler {
    private static var current: AvatarChat?
    // Held here: transcribe() bails out quietly if its Transcriber is gone.
    private static let transcriber = Transcriber()

    static func toggle(near avatar: NSRect, pinnedTo parent: NSWindow, agent: MOMGenerator, recording: @escaping () -> Bool) {
        if let c = current { c.window.close(); return }
        let c = AvatarChat(agent: agent, recording: recording, near: avatar)
        current = c
        c.window.makeKeyAndOrderFront(nil)
        // Follows Nikxel when it moves, re-placed each time so it stays on the side with room and on screen.
        let start = parent.frame.origin
        c.moved = NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: parent, queue: .main) { [weak c] _ in
            let o = parent.frame.origin
            c?.place(near: avatar.offsetBy(dx: o.x - start.x, dy: o.y - start.y))
        }
        c.window.makeFirstResponder(c.web)  // type and Esc at once, without clicking in first
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
    private var hitTimer: Timer?
    private var moved: NSObjectProtocol?
    private var hits: [NSRect] = []  // page coordinates, top-left origin
    // Fetched once as the box opens, while the user types; every question reuses it.
    private var feed: (feed: [[String: Any]], offline: Bool) = ([], true)
    private var waSnapshot = ""   // a read of WhatsApp at open time (unread, recent chats, open thread)
    private let feedReady = DispatchGroup()
    private let voiceURL = URL(fileURLWithPath: NSHomeDirectory() + "/.nikxel/edits/chat-voice.wav")

    private init(agent: MOMGenerator, recording: @escaping () -> Bool, near avatar: NSRect) {
        self.agent = agent
        self.recording = recording
        let (frame, flip) = AvatarChat.frame(near: avatar, size: NSSize(width: 340, height: 460))
        window = KeyPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        let config = WKWebViewConfiguration()
        config.userContentController.addUserScript(WKUserScript(
            source: "var startRecording = \(recording()); var flip = \(flip);", injectionTime: .atDocumentStart, forMainFrameOnly: true))
        web = WKWebView(frame: .zero, configuration: config)
        super.init()
        config.userContentController.add(self, name: "nx")

        window.level = .floating
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false  // no panel: the bubbles and field carry their own shadows
        window.hidesOnDeactivate = false  // clicking elsewhere leaves it up
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.delegate = self

        web.setValue(false, forKey: "drawsBackground")
        window.contentView = web
        window.ignoresMouseEvents = true  // until the page says where its bubbles are
        web.loadHTMLString(AvatarChat.page, baseURL: nil)

        feedReady.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            self.feed = CloudSync.projectFeed(get: CloudSync.getter(timeout: 3))
            self.waSnapshot = AvatarChat.waContextBlock() ?? ""   // read WhatsApp once; every question reuses it
            self.feedReady.leave()
        }

        // A recording can start or stop while the box is open; the mic follows it.
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.web.evaluateJavaScript("setRecording(\(self.recording()))")
        }
        // A clear window still swallows clicks, so it takes them only over what the page reported.
        hitTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self else { return }
            let p = self.window.mouseLocationOutsideOfEventStream, h = self.window.frame.height
            let over = self.hits.contains { $0.contains(NSPoint(x: p.x, y: h - p.y)) }
            if self.window.ignoresMouseEvents == over { self.window.ignoresMouseEvents = !over }
        }
    }

    /// Beside the avatar on the side with room (right first), the field level with its bottom, kept on screen.
    /// flip: the box sits left of the avatar, so Nikxel's bubbles go on the right, next to it.
    private static func frame(near avatar: NSRect, size s: NSSize) -> (NSRect, Bool) {
        let scr = NSScreen.screens.first { $0.frame.intersects(avatar) } ?? NSScreen.main ?? NSScreen.screens[0]
        let v = scr.visibleFrame, gap: CGFloat = 4
        let right = v.maxX - avatar.maxX, left = avatar.minX - v.minX
        let flip = right < s.width + gap && left > right
        let x = min(max(flip ? avatar.minX - gap - s.width : avatar.maxX + gap, v.minX), v.maxX - s.width)
        let y = min(max(avatar.minY, v.minY), v.maxY - s.height)
        return (NSRect(origin: NSPoint(x: x, y: y), size: s), flip)
    }

    private func place(near avatar: NSRect) {
        let (f, flip) = AvatarChat.frame(near: avatar, size: window.frame.size)
        window.setFrame(f, display: true)
        web.evaluateJavaScript("document.body.classList.toggle('flip', \(flip))")
    }

    func windowWillClose(_ notification: Notification) {
        timer?.invalidate(); timer = nil
        hitTimer?.invalidate(); hitTimer = nil
        if let m = moved { NotificationCenter.default.removeObserver(m); moved = nil }
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
        case "hit":
            hits = (body["rects"] as? [[Double]] ?? []).filter { $0.count == 4 }.map { NSRect(x: $0[0], y: $0[1], width: $0[2], height: $0[3]) }
        case "send":
            let history = self.history, agent = self.agent, today = Date()
            DispatchQueue.global(qos: .userInitiated).async {
                let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/nikxel")
                self.feedReady.wait()
                let (feed, offline) = self.feed
                // What Nikxel has learned about the user (names, projects, people) goes first.
                // What Nikxel is doing right now and has done today (apps, code, agent asks),
                // then the WhatsApp read, then the written summaries/notes/projects.
                let live = (DayLogger.current?.liveContext(inMeeting: MeetingDetector.shared.isInMeeting)).map { "### right now\n\($0)" } ?? ""
                let context = [NikxelSettings.userContextBlock, live, self.waSnapshot,
                               ChatContext.build(ChatContext.localBlocks(root: root, today: today) + ChatContext.projectBlocks(feed),
                                                 cap: ChatContext.cap)].filter { !$0.isEmpty }.joined(separator: "\n\n")
                // "make a task to …" creates one in ERP, drafted from the same
                // meeting/WhatsApp/project context, then opens it to review.
                if ERP.looksLikeTaskRequest(text) {
                    let reply = AvatarChat.makeERPTask(request: text, context: context, today: today, agent: agent)
                    DispatchQueue.main.async {
                        self.history.append((q: text, a: reply))
                        self.resolve(id, ["text": reply, "offline": offline, "error": false])
                    }
                    return
                }
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
                    self.resolve(id, ["text": reply, "offline": offline, "error": answer == nil])
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

    /// Draft an ERP task from the chat request plus context, create it, and open
    /// the record to review — the chat-side twin of the summary's Assign button.
    /// Runs on the send background queue, so the network calls are off main.
    private static func makeERPTask(request: String, context: String, today: Date, agent: MOMGenerator) -> String {
        guard ERP.isConnected else { return "Connect Forklyft ERP in Nikxel first, then ask again." }
        guard ERP.hasLiveSession() else {
            return "Your ERP session has ended — reconnect Forklyft ERP from the Nikxel menu, then try again."
        }
        let draftReply: String   // context already carries the live activity + WhatsApp read
        do {
            draftReply = try agent.runPrompt(ERP.taskDraftPrompt(request: request, context: context, today: today),
                                             kind: "erp-task", claudeModel: "haiku", timeout: 30)
        } catch MOMGenerator.MOMError.agentNotFound {
            return "Connect Claude in Settings to use chat."
        } catch {
            return "⚠︎ \(error)"
        }
        guard let draft = ERP.parseTaskDraft(draftReply) else {
            return "I couldn't turn that into a task. Try naming what to do, e.g. “make a task to send Piyush the invoice by Friday”."
        }
        let r = ERP.createTask(draft: draft)
        guard let url = r.url else { return r.error ?? "ERP didn't create the task." }
        if let u = URL(string: url) { DispatchQueue.main.async { NSWorkspace.shared.open(u) } }
        var line = "Created “\(draft.title)” in ERP"
        if let a = draft.assignee { line += " · for \(a)" }
        if let p = draft.project { line += " · \(p)" }
        if let d = draft.due { line += " · due \(d)" }
        return line + ". Opening it so you can review and edit."
    }

    /// A read of WhatsApp for the chat: who's waiting (unread), the recent chats,
    /// and the thread on screen in full — best-effort, no chat switching, only
    /// when the WA browser is up and logged in. nil when there's nothing.
    private static func waContextBlock() -> String? {
        guard ChromeBot.isPortOpen(), ChromeWhatsApp.isLoggedIn() else { return nil }
        var parts: [String] = []
        let unread = ChromeWhatsApp.unreadChats()
        if !unread.isEmpty {
            parts.append("Unread (who's waiting on you):\n" + unread.prefix(15).map {
                "- \($0.name) (\($0.unread)): \($0.preview.prefix(140))" }.joined(separator: "\n"))
        }
        let recent = ChromeWhatsApp.allChatsPreview(limit: 25)
        if !recent.isEmpty {
            parts.append("Recent chats (newest first):\n" + recent.map {
                "- \($0.name): \($0.preview.prefix(140))" }.joined(separator: "\n"))
        }
        // readThread (not readMessages) keeps direction, so each line is labelled
        // by who sent it — otherwise the chat can't tell your words from theirs.
        let thread = ChromeWhatsApp.readThread()
        if !thread.isEmpty {
            let who = ChromeWhatsApp.conversationHeader() ?? "them"
            let lines = thread.suffix(14).map { "\($0.outgoing ? "You" : who): \($0.text)" }
            parts.append("Open thread with \(who) (each line is labelled with who sent it):\n" + lines.joined(separator: "\n"))
        }
        guard !parts.isEmpty else { return nil }
        return "### whatsapp\n" + parts.joined(separator: "\n\n")
    }

    /// Same markup and CSS as windows/src/renderer/avatarChat.html.
    private static let page = #"""
<!doctype html><html><head><meta charset="utf-8">
<style>
:root{--glass:rgba(255,255,255,.66);--rim:rgba(255,255,255,.85);--fg:#0d0d0d;--muted:rgba(60,60,67,.62);--me:rgba(32,32,34,.86);--me-fg:#fff;--line:rgba(0,0,0,.08);--go:#0d0d0d;--go-fg:#fff;--shade:0 6px 22px rgba(0,0,0,.16),0 1px 3px rgba(0,0,0,.08);color-scheme:light dark}
@media (prefers-color-scheme:dark){:root{--glass:rgba(38,38,42,.7);--rim:rgba(255,255,255,.14);--fg:#ececec;--muted:rgba(235,235,245,.55);--me:rgba(255,255,255,.88);--me-fg:#0d0d0d;--line:rgba(255,255,255,.1);--go:#ececec;--go-fg:#0d0d0d;--shade:0 6px 22px rgba(0,0,0,.45)}}
*{box-sizing:border-box}
html,body{height:100%;margin:0;background:transparent;overflow:hidden}
body{display:flex;flex-direction:column;padding:6px 10px 10px;color:var(--fg);font:13.5px/1.5 system-ui,-apple-system,"Segoe UI",sans-serif;-webkit-user-select:none;user-select:none}
#log{flex:1;min-height:0;overflow-y:auto;display:flex;flex-direction:column;gap:8px;padding:28px 4px 10px;scrollbar-width:none;-webkit-mask-image:linear-gradient(to bottom,transparent 0,#000 40px)}
#log::-webkit-scrollbar{display:none}
#log>:first-child{margin-top:auto}
.msg{max-width:86%;padding:8px 13px;border-radius:18px;white-space:pre-wrap;word-wrap:break-word;-webkit-user-select:text;user-select:text;animation:in .22s ease-out;box-shadow:var(--shade)}
.bot{align-self:flex-start;background:var(--glass);border:1px solid var(--rim);border-bottom-left-radius:6px}
.me{align-self:flex-end;background:var(--me);color:var(--me-fg);border-bottom-right-radius:6px}
.msg.md{white-space:normal}
.msg.md p{margin:0 0 6px}.msg.md p:last-child{margin:0}
.msg.md ul,.msg.md ol{margin:4px 0;padding-left:18px}.msg.md li{margin:2px 0}
.msg.md strong{font-weight:650}.msg.md em{font-style:italic}
.msg.md code{font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:12px;background:var(--line);padding:1px 4px;border-radius:4px}
.msg.md .h{display:block;font-weight:650;margin:5px 0 2px}.msg.md .h:first-child{margin-top:0}
body.flip .bot{align-self:flex-end;border-bottom-left-radius:18px;border-bottom-right-radius:6px}
body.flip .me{align-self:flex-start;border-bottom-right-radius:18px;border-bottom-left-radius:6px}
.dots{display:inline-flex;gap:4px;padding:4px 0}
.dots i{width:6px;height:6px;border-radius:50%;background:var(--muted);animation:bob 1.1s infinite}
.dots i:nth-child(2){animation-delay:.15s}.dots i:nth-child(3){animation-delay:.3s}
.hint{color:var(--muted);font-size:11.5px;margin-left:6px}
@keyframes bob{0%,70%,100%{opacity:.3;transform:translateY(0)}35%{opacity:1;transform:translateY(-3px)}}
@keyframes in{from{opacity:0;transform:translateY(6px) scale(.98)}}
#offline{display:none;align-self:center;margin-bottom:6px;color:var(--muted);font-size:11px;padding:2px 9px;border-radius:999px;background:var(--glass);border:1px solid var(--rim)}
#offline.on{display:block}
form{flex:none;display:flex;align-items:center;gap:4px;padding:4px 4px 4px 15px;border:1px solid var(--rim);border-radius:999px;background:var(--glass);box-shadow:var(--shade)}
input{flex:1;min-width:0;border:0;outline:0;background:transparent;color:var(--fg);font:inherit;padding:6px 0}
input::placeholder{color:var(--muted)}
.icon{width:32px;height:32px;border-radius:50%;border:0;display:grid;place-items:center;cursor:pointer;background:transparent;color:var(--muted);transition:background .15s,opacity .15s,transform .1s;flex:none}
.icon:hover:not(:disabled){background:var(--line)}
.icon:active:not(:disabled){transform:scale(.94)}
.icon:disabled{opacity:.3;cursor:default}
.icon svg{width:16px;height:16px}
#send{background:var(--go);color:var(--go-fg)}
#send:hover:not(:disabled){background:var(--go);opacity:.85}
#mic.rec{background:#ff3b30;color:#fff;animation:pulse 1.3s infinite}
@keyframes pulse{0%{box-shadow:0 0 0 0 rgba(255,59,48,.55)}100%{box-shadow:0 0 0 10px rgba(255,59,48,0)}}
</style></head><body>
<div id="log"></div>
<span id="offline">projects offline</span>
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
  micStop: function () { return ask("mic"); },
  hit: function (r) { webkit.messageHandlers.nx.postMessage({ type: "hit", rects: r }); }
};
var flipped = typeof flip !== "undefined" && flip;
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
// A small, safe markdown subset so replies (bold, bullets, headings, code) read
// cleanly instead of showing raw ** and - . Everything is escaped first.
function esc(s){return String(s).replace(/[&<>]/g,function(c){return {"&":"&amp;","<":"&lt;",">":"&gt;"}[c];});}
function mdInline(s){return esc(s)
  .replace(/\*\*([^*]+)\*\*/g,"<strong>$1</strong>")
  .replace(/`([^`]+)`/g,"<code>$1</code>")
  .replace(/(^|[^*])\*([^*\n]+)\*/g,"$1<em>$2</em>");}
function md(text){
  var lines=String(text).split(/\r?\n/),out=[],list=null,para=[];
  function fp(){ if(para.length){ out.push("<p>"+para.join("<br>")+"</p>"); para=[]; } }
  function fl(){ if(list){ out.push("<"+list.t+">"+list.i.join("")+"</"+list.t+">"); list=null; } }
  for(var k=0;k<lines.length;k++){
    var t=lines[k].trim(), b=t.match(/^[-*]\s+(.*)/), o=t.match(/^\d+[.)]\s+(.*)/), h=t.match(/^#{1,6}\s+(.*)/);
    if(b){ fp(); if(!list||list.t!=="ul"){fl();list={t:"ul",i:[]};} list.i.push("<li>"+mdInline(b[1])+"</li>"); }
    else if(o){ fp(); if(!list||list.t!=="ol"){fl();list={t:"ol",i:[]};} list.i.push("<li>"+mdInline(o[1])+"</li>"); }
    else if(h){ fp(); fl(); out.push('<span class="h">'+mdInline(h[1])+"</span>"); }
    else if(t===""){ fp(); fl(); }
    else { fl(); para.push(mdInline(t)); }
  }
  fp(); fl(); return out.join("");
}
function settle(d, text) { d.className = "msg bot md"; d.innerHTML = md(text); log.scrollTop = log.scrollHeight; }
function run(text) {
  bubble("me", text);
  var w = typing("thinking…"); busy = true; sync();
  api.send(text).then(function (r) {
    settle(w, r.text); document.getElementById("offline").classList.toggle("on", !!r.offline);
    if (r.error && !input.value) input.value = text;  // keep the question to try again
    busy = false; sync(); input.focus();
  });
}
document.getElementById("f").onsubmit = function (e) {
  e.preventDefault(); var t = input.value.trim(); if (!t || busy) return;
  input.value = ""; run(t);
};
input.oninput = sync;
// Only the bubbles and the field take clicks; the clear space around them passes through.
function report() {
  var L = log.getBoundingClientRect(), r = [];
  [].forEach.call(log.querySelectorAll(".msg"), function (e) {
    var b = e.getBoundingClientRect(), t = Math.max(b.top, L.top), u = Math.min(b.bottom, L.bottom);
    if (u > t) r.push([b.left, t, b.width, u - t]);
  });
  [document.getElementById("f"), document.getElementById("offline")].forEach(function (e) {
    var b = e.getBoundingClientRect(); if (b.height) r.push([b.left, b.top, b.width, b.height]);
  });
  api.hit(r);
}
new MutationObserver(report).observe(document.body, { childList: true, subtree: true, characterData: true, attributes: true });
log.onscroll = report; window.onresize = report;
if (flipped) document.body.classList.add("flip");
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
