import AppKit
import AVFoundation
import WebKit

/// "About Me" — a window where the user tells Nikxel who they are, their work,
/// their company and what they're aiming for, by typing or by talking (the mic
/// records, Whisper types it in). Saved to NikxelSettings.userContext and fed
/// into the summary, meeting and reply prompts so everything stays in line with
/// it. Same voice bridge as the Edit chat (src/PageEdit.swift); Windows mirror
/// is windows/src/renderer/aboutMe.*.
final class AboutMe: NSObject, NSWindowDelegate, WKScriptMessageHandler {
    private static var shared: AboutMe?
    private static let transcriber = Transcriber()  // held live, so transcribe() doesn't lose its engine

    private let window: NSPanel
    private let web: WKWebView
    private var recorder: AVAudioRecorder?
    private let voiceURL = URL(fileURLWithPath: NSHomeDirectory() + "/.nikxel/aboutme-voice.wav")

    static func show() {
        if shared == nil { shared = AboutMe() }
        shared?.window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private override init() {
        window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 520),
                         styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        let config = WKWebViewConfiguration()
        web = WKWebView(frame: .zero, configuration: config)
        super.init()
        config.userContentController.add(self, name: "nx")

        window.title = "About Me"
        window.titlebarAppearsTransparent = true
        window.backgroundColor = NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.11, green: 0.11, blue: 0.118, alpha: 1) : NSColor(srgbRed: 0.969, green: 0.969, blue: 0.976, alpha: 1) }
        window.minSize = NSSize(width: 360, height: 420)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = web
        window.center()

        let current = NoteExporter.escape(NikxelSettings.userContext)
        web.loadHTMLString(Self.page.replacingOccurrences(of: "__CONTEXT__", with: current), baseURL: nil)
    }

    func windowWillClose(_ notification: Notification) {
        recorder?.stop(); recorder = nil
        web.configuration.userContentController.removeScriptMessageHandler(forName: "nx")
        AboutMe.shared = nil
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String,
              let id = body["id"] as? Int else { return }
        let text = body["text"] as? String ?? ""
        switch type {
        case "save":
            NikxelSettings.userContext = text
            cblog("AboutMe: context saved (\(text.count) chars)")
            resolve(id, "saved")
        case "mic":
            if let r = recorder {
                r.stop(); recorder = nil
                AboutMe.transcriber.transcribe(audioURL: voiceURL, outputFormat: .txt) { result in
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

    /// Same markup/behaviour as windows/src/renderer/aboutMe.html; only the
    /// bridge (webkit.messageHandlers) and the mic (recorded natively) differ.
    private static let page = #"""
<!doctype html><html><head><meta charset="utf-8">
<style>
:root{--bg:#f7f7f9;--fg:#1d1d1f;--muted:#6e6e73;--line:#e3e3e8;--accent:#5e5ce6;--field:#fff;color-scheme:light dark}
@media (prefers-color-scheme:dark){:root{--bg:#1c1c1e;--fg:#f5f5f7;--muted:#98989d;--line:#38383a;--field:#2c2c2e}}
*{box-sizing:border-box}
html,body{height:100%;margin:0}
body{background:var(--bg);color:var(--fg);font:14px/1.5 -apple-system,system-ui,"Segoe UI",sans-serif;display:flex;flex-direction:column;padding:16px;gap:12px}
h1{font-size:17px;margin:0}
p.hint{margin:0;color:var(--muted);font-size:12.5px}
textarea{flex:1;min-height:200px;width:100%;resize:none;border:1px solid var(--line);border-radius:12px;background:var(--field);color:var(--fg);font:inherit;padding:12px}
textarea:focus{outline:2px solid var(--accent);outline-offset:-1px}
.row{display:flex;gap:8px;align-items:center}
button{font:inherit;font-weight:600;border:0;border-radius:999px;padding:9px 16px;cursor:pointer}
.mic{background:var(--field);color:var(--fg);border:1px solid var(--line)}
.mic.rec{background:#ff3b30;color:#fff;border-color:#ff3b30}
.save{background:#1d1d1f;color:#fff;margin-left:auto}
@media (prefers-color-scheme:dark){.save{background:#f5f5f7;color:#1d1d1f}}
button:disabled{opacity:.5;cursor:default}
.msg{color:var(--muted);font-size:12px;min-height:1em}
</style></head><body>
<h1>About me</h1>
<p class="hint">Tell Nikxel who you are — your work, your company, what you're aiming for. It keeps this in mind across your summaries, meeting notes and replies. Type it, or tap the mic and talk.</p>
<textarea id="t" placeholder="e.g. I'm a developer at Forklyft, building the Produce POS and Nikxel. I care about shipping fast and keeping things simple…">__CONTEXT__</textarea>
<div class="row">
  <button class="mic" id="mic" type="button">🎤 Talk</button>
  <span class="msg" id="msg"></span>
  <button class="save" id="save" type="button">Save</button>
</div>
<script>
var seq = 0, pending = {};
window.nx = { resolve: function (id, text) { var f = pending[id]; if (f) { delete pending[id]; f(text); } } };
function ask(type, text) { return new Promise(function (r) { var id = ++seq; pending[id] = r; webkit.messageHandlers.nx.postMessage({ type: type, id: id, text: text || "" }); }); }
var t = document.getElementById("t"), mic = document.getElementById("mic"), save = document.getElementById("save"), msg = document.getElementById("msg");
var recording = false, busy = false;
function say(s){ msg.textContent = s || ""; }
mic.onclick = async function () {
  if (busy) return;
  if (!recording) {
    var r = await ask("mic");
    if (r === "recording") { recording = true; mic.classList.add("rec"); mic.textContent = "● Stop"; say("Listening…"); }
    else say("Couldn't use the microphone.");
    return;
  }
  recording = false; mic.classList.remove("rec"); mic.textContent = "🎤 Talk"; busy = true; say("Typing it in…");
  var heard = await ask("mic"); busy = false; say("");
  if (heard) { t.value = (t.value.trim() ? t.value.trim() + " " : "") + heard; t.focus(); }
  else say("I didn't catch that — try again or type it.");
};
save.onclick = async function () { save.disabled = true; await ask("save", t.value); say("Saved ✓"); save.disabled = false; };
t.focus();
</script></body></html>
"""#
}
