import AppKit
import Network

/// The Share button on summary pages. The page is a local file, so it can't
/// reach WhatsApp itself: it asks Nikxel over localhost, and Nikxel sends the
/// file from the WhatsApp window it already drives. "Copy" puts the file on
/// the clipboard, to paste into any chat or group by hand.
///
/// Any web page can call localhost, so every request carries a per-install
/// token that only pages Nikxel wrote contain, and only .html files under
/// ~/Documents/nikxel can be sent.
enum PageShare {
    static let port: UInt16 = 47120
    private static let queue = DispatchQueue(label: "nikxel.share")
    private static var listener: NWListener?

    static let token: String = {
        let url = URL(fileURLWithPath: NSHomeDirectory() + "/.nikxel/share_token")
        if let t = try? String(contentsOf: url, encoding: .utf8), t.count >= 32 { return t }
        let t = UUID().uuidString + UUID().uuidString
        try? t.write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return t
    }()

    /// Goes right before </body>. Marked, so a sent copy goes out without it.
    /// `editable` adds the Edit button (PageEdit) beside Share.
    static func widget(editable: Bool) -> String {
        widgetTemplate.replacingOccurrences(of: "__NIKXEL_TOKEN__", with: token)
            .replacingOccurrences(of: "__NIKXEL_EDIT__", with: editable ? #"<button class="nx-btn nx-edit" type="button">Edit</button>"# : "")
    }

    static func strip(_ html: String) -> String {
        html.replacingOccurrences(of: #"<!--nikxel-share-->[\s\S]*?<!--/nikxel-share-->"#, with: "", options: .regularExpression)
    }

    // MARK: - Server

    static func start() {
        _ = token
        let params = NWParameters.tcp
        params.acceptLocalOnly = true
        params.requiredInterfaceType = .loopback
        guard let l = try? NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!) else {
            cblog("PageShare: port \(port) is busy — Share buttons won't work"); return
        }
        listener = l
        l.newConnectionHandler = { conn in
            conn.start(queue: queue)
            conn.receive(minimumIncompleteLength: 1, maximumLength: 16384) { data, _, _, _ in
                let req = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                let body = handle(req)
                let json = (try? JSONSerialization.data(withJSONObject: body)) ?? Data("{}".utf8)
                var head = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nAccess-Control-Allow-Origin: *\r\n"
                head += "Content-Length: \(json.count)\r\nConnection: close\r\n\r\n"
                conn.send(content: Data(head.utf8) + json, completion: .contentProcessed { _ in conn.cancel() })
            }
        }
        l.start(queue: queue)
    }

    private static func handle(_ req: String) -> [String: Any] {
        let q = { (k: String) in GoogleAuth.queryParam(request: req, key: k) }
        guard q("t") == token else { return ["error": "This page can only be shared from the Mac that made it."] }
        let route = req.split(separator: " ").dropFirst().first?.split(separator: "?").first ?? ""
        guard let file = allowedFile(q("path")) else { return ["error": "Only Nikxel's own pages can be shared."] }

        switch route {
        case "/edit":
            guard PageEdit.editable(file) else { return ["error": "This summary can't be edited."] }
            DispatchQueue.main.async { EditChat.show(file) }
            return ["ok": true]
        case "/version":
            let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            return ["v": date?.timeIntervalSince1970 ?? 0]
        case "/copy":
            let tmp = URL(fileURLWithPath: NSHomeDirectory() + "/.nikxel/share")
            try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            let out = tmp.appendingPathComponent(file.lastPathComponent)
            guard let html = try? String(contentsOf: file, encoding: .utf8),
                  (try? strip(html).write(to: out, atomically: true, encoding: .utf8)) != nil else {
                return ["error": "Couldn't read the page."]
            }
            DispatchQueue.main.sync {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.writeObjects([out as NSURL])
            }
            return ["ok": true]
        case "/chats", "/send":
            guard NikxelSettings.whatsappConnected else { return ["error": "WhatsApp isn't connected in Nikxel."] }
            var result: [String: Any] = [:]
            if route == "/chats" {
                ChatbotEngine.shared.withPollingHeld {
                    result = ["chats": ChromeWhatsApp.searchChats(q("q") ?? "")]; return true
                }
                return result
            }
            guard let to = q("to"), !to.isEmpty,
                  let html = try? String(contentsOf: file, encoding: .utf8) else { return ["error": "Nothing to send."] }
            ChatbotEngine.shared.withPollingHeld {
                guard ChromeWhatsApp.openChatBySearch(to) else {
                    result = ["error": "Couldn't open \(to)'s chat in WhatsApp."]; return true
                }
                result = ChromeWhatsApp.sendFile(named: file.lastPathComponent, data: Data(strip(html).utf8), type: "text/html")
                    ? ["ok": true] : ["error": "WhatsApp didn't take the file."]
                return true
            }
            cblog("PageShare: \(file.lastPathComponent) → '\(to)': \(result["ok"] != nil ? "sent" : "\(result["error"] ?? "")")")
            return result
        default:
            return ["error": "Unknown request."]
        }
    }

    /// The page's own path, if it's an .html file Nikxel writes.
    private static func allowedFile(_ path: String?) -> URL? {
        guard let path = path else { return nil }
        let root = URL(fileURLWithPath: NSHomeDirectory() + "/Documents/nikxel").resolvingSymlinksInPath().path + "/"
        let url = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        guard url.path.hasPrefix(root), url.pathExtension == "html",
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    // MARK: - The button

    /// Same markup in windows/src/main/system/pageShare.ts.
    private static let widgetTemplate = #"""
<!--nikxel-share--><div id="nx-share">__NIKXEL_EDIT__<button class="nx-btn nx-sharebtn" type="button">Share</button><div class="nx-pop" hidden>
<button class="nx-copy" type="button">Copy file</button><div class="nx-or">or send on WhatsApp to</div>
<input class="nx-q" placeholder="Search a chat or contact"><div class="nx-list"></div><div class="nx-msg"></div></div></div>
<style>
#nx-share{position:fixed;right:20px;bottom:20px;z-index:99;font:14px/1.4 system-ui,-apple-system,"Segoe UI",sans-serif;color:#1d1d1f}
#nx-share .nx-btn{background:#1d1d1f;color:#fff;border:0;border-radius:999px;padding:10px 18px;font:inherit;font-weight:600;cursor:pointer;box-shadow:0 4px 16px rgba(0,0,0,.18)}
#nx-share .nx-edit{margin-right:8px;background:#fff;color:#1d1d1f}
#nx-share .nx-pop{position:absolute;right:0;bottom:52px;width:290px;background:#fff;border-radius:14px;padding:12px;box-shadow:0 10px 40px rgba(0,0,0,.22)}
#nx-share .nx-pop[hidden]{display:none}
#nx-share .nx-copy{width:100%;padding:9px;border:1px solid #d2d2d7;border-radius:9px;background:#f5f5f7;font:inherit;cursor:pointer}
#nx-share .nx-or{margin:12px 2px 6px;color:#6e6e73;font-size:12px}
#nx-share .nx-q{width:100%;box-sizing:border-box;padding:8px 10px;border:1px solid #d2d2d7;border-radius:9px;font:inherit}
#nx-share .nx-list{max-height:230px;overflow:auto;margin-top:6px}
#nx-share .nx-list button{display:block;width:100%;text-align:left;padding:8px 10px;border:0;border-radius:8px;background:none;font:inherit;color:inherit;cursor:pointer}
#nx-share .nx-list button:hover{background:#f0f0f3}
#nx-share .nx-msg{margin-top:8px;font-size:12px;color:#6e6e73}
#nx-share .nx-msg:empty{display:none}
@media print{#nx-share{display:none}}
</style>
<script>(function(){
  var T = "__NIKXEL_TOKEN__", P = "http://127.0.0.1:47120/";
  var path = decodeURIComponent(location.pathname).replace(/^\/([A-Za-z]:)/, "$1");
  var root = document.getElementById("nx-share"), pop = root.querySelector(".nx-pop");
  var q = root.querySelector(".nx-q"), list = root.querySelector(".nx-list"), msg = root.querySelector(".nx-msg");
  function call(route, extra) {
    var p = new URLSearchParams(extra || {}); p.set("t", T); p.set("path", path);
    return fetch(P + route + "?" + p).then(function (r) { return r.json(); },
      function () { return { error: "Open Nikxel to share." }; });
  }
  function say(t) { msg.textContent = t || ""; }
  var timer, asked = 0;
  function load() {
    var n = ++asked; say("Looking…");
    call("chats", { q: q.value.trim() }).then(function (r) {
      if (n !== asked) return;
      list.innerHTML = ""; say(r.error || (r.chats.length ? "" : "No chats found."));
      (r.chats || []).forEach(function (name) {
        var b = document.createElement("button"); b.type = "button"; b.textContent = name;
        b.onclick = function () {
          if (!confirm("Send this page to " + name + " on WhatsApp?")) return;
          say("Sending to " + name + "…");
          call("send", { to: name }).then(function (r) { say(r.error || "Sent to " + name + " ✓"); });
        };
        list.appendChild(b);
      });
    });
  }
  // After Edit, watch the file and reload when the chat window changes it.
  // sessionStorage keeps the watch going across that reload.
  var v = 0;
  function watch() {
    call("version").then(function (r) {
      // No answer (Nikxel restarting): keep asking rather than give up.
      if (r.v && v && r.v !== v) { location.reload(); return; }
      if (r.v) v = r.v;
      setTimeout(watch, 2000);
    });
  }
  try { if (sessionStorage.getItem("nx-editing")) watch(); } catch (e) {}
  var edit = root.querySelector(".nx-edit");
  if (edit) edit.onclick = function () {
    call("edit").then(function (r) {
      if (r.error) { pop.hidden = false; say(r.error); return; }
      try { sessionStorage.setItem("nx-editing", "1"); } catch (e) {}
      if (!v) watch();
    });
  };
  root.querySelector(".nx-sharebtn").onclick = function () {
    pop.hidden = !pop.hidden; if (!pop.hidden) { q.focus(); load(); }
  };
  q.oninput = function () { clearTimeout(timer); timer = setTimeout(load, 500); };
  root.querySelector(".nx-copy").onclick = function () {
    call("copy").then(function (r) { say(r.error || "Copied. Paste it into any WhatsApp chat or group."); });
  };
  document.addEventListener("click", function (e) { if (!root.contains(e.target)) pop.hidden = true; });
})();</script><!--/nikxel-share-->
"""#
}
