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

    /// Re-inject the current widget into pages Nikxel already wrote, so old
    /// summaries gain new buttons (Assign) without being regenerated. Keeps
    /// each page's existing Edit affordance, and skips pages already upgraded.
    static func migrateWidgets() {
        let root = URL(fileURLWithPath: NSHomeDirectory() + "/Documents/nikxel")
        guard let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil),
              let re = try? NSRegularExpression(pattern: "<!--nikxel-share-->[\\s\\S]*?<!--/nikxel-share-->") else { return }
        for case let url as URL in en where url.pathExtension == "html" {
            guard let html = try? String(contentsOf: url, encoding: .utf8),
                  html.contains("<!--nikxel-share-->"), !html.contains("<!--nxw4-->") else { continue }
            let block = widget(editable: html.contains("nx-edit"))
            let out = re.stringByReplacingMatches(in: html, range: NSRange(html.startIndex..., in: html),
                                                  withTemplate: NSRegularExpression.escapedTemplate(for: block))
            try? out.write(to: url, atomically: true, encoding: .utf8)
        }
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
        queue.async { migrateWidgets() }   // give existing pages the Assign button
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
        case "/task":
            // A ticked box on a day page. The .md is what tomorrow's summary
            // and the morning card read, so "— done" there drops the task.
            let md = file.deletingPathExtension().appendingPathExtension("md"), done = q("done") == "1"
            guard let i = q("i").flatMap(Int.init), let text = try? String(contentsOf: md, encoding: .utf8),
                  let updated = DayPage.markTask(in: text, index: i, done: done),
                  let html = try? String(contentsOf: file, encoding: .utf8),
                  (try? updated.write(to: md, atomically: true, encoding: .utf8)) != nil else {
                return ["error": "Couldn't update that task."]
            }
            let ticked = html.replacingOccurrences(of: "data-i=\"\(i)\"( checked)?", with: "data-i=\"\(i)\"" + (done ? " checked" : ""), options: .regularExpression)
            try? ticked.write(to: file, atomically: true, encoding: .utf8)
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
        case "/client":
            // Render the client-facing page from the meeting's "## Client
            // Summary" section and hand back its file URL. The page carries its
            // own Share buttons, so the user previews it, then sends it.
            let mdURL = file.deletingPathExtension().appendingPathExtension("md")
            guard let md = try? String(contentsOf: mdURL, encoding: .utf8),
                  let clientMd = NotePage.clientMarkdown(from: md) else {
                return ["error": "This summary has no client version."]
            }
            let clientFile = file.deletingPathExtension().appendingPathExtension("client").appendingPathExtension("html")
            guard (try? NotePage.html(from: clientMd).write(to: clientFile, atomically: true, encoding: .utf8)) != nil else {
                return ["error": "Couldn't build the client summary."]
            }
            return ["url": clientFile.absoluteString]
        case "/erp":
            // Just whether Assign buttons should show. Matching + create happen
            // server-side on /assign, so the page needs no roster.
            return ["connected": ERP.isConnected]
        case "/assign":
            guard ERP.isConnected else { return ["error": "Connect Forklyft ERP in Nikxel first."] }
            guard ERP.hasLiveSession() else {
                return ["error": "Your ERP session has ended. Reconnect Forklyft ERP from the Nikxel menu, then try again."]
            }
            // The page sends the full action-item text; we make a short title
            // and a context-rich description, since the assignee may not have
            // been in the meeting. Only the title is required in Odoo.
            guard let item = q("title"), !item.isEmpty else { return ["error": "No task text."] }
            let who = q("who") ?? ""
            let uid = who.isEmpty ? nil : ERP.matchUser(who, in: ERP.assignableUsers())?.id
            let deadline = (q("due")).flatMap { $0.isEmpty ? nil : $0 + " 17:00:00" }  // date → datetime
            let title = ERP.shortTitle(item)
            // Prefer the rich brief Nikxel already wrote for software tasks;
            // fall back to the plain task + meeting origin for the rest.
            let mdURL = file.deletingPathExtension().appendingPathExtension("md")
            let desc = ERP.briefFromAgentPrompts(item: item, mdURL: mdURL)
                ?? ERP.taskDescription(item: item, context: meetingContext(file))
            guard let tid = ERP.createTask(title: title, descriptionHTML: desc,
                                           assigneeUserID: uid, projectID: nil, deadline: deadline) else {
                return ["error": "ERP didn't create the task."]
            }
            cblog("ERP: created task \(tid) — \(title.prefix(60))")
            return ["url": ERP.taskURL(id: tid)]
        default:
            return ["error": "Unknown request."]
        }
    }

    /// A one-line meeting context for a task description: the summary's
    /// headline and the meeting date, so an assignee who wasn't there has a
    /// pointer to what it was about.
    private static func meetingContext(_ file: URL) -> String {
        let stem = file.deletingPathExtension().lastPathComponent        // 2026-11-12-103105
        let date = stem.prefix(10)
        var headline = ""
        if let html = try? String(contentsOf: file, encoding: .utf8),
           let r = html.range(of: #"<h1[^>]*>[\s\S]*?</h1>"#, options: .regularExpression) {
            headline = String(html[r])
                .replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if headline.isEmpty { return "Came out of a team meeting on \(date)." }
        return "Came out of a team meeting on \(date): \(headline)"
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
<!--nikxel-share--><!--nxw4--><div id="nx-share">__NIKXEL_EDIT__<button class="nx-btn nx-sharebtn" type="button">Share</button><div class="nx-pop" hidden>
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
li.task .nx-assign{margin-left:8px;vertical-align:middle;background:#1d1d1f;color:#fff;border:0;border-radius:999px;padding:3px 11px;font:600 12px/1 system-ui,-apple-system,"Segoe UI",sans-serif;cursor:pointer;opacity:.85}
li.task .nx-assign:hover{opacity:1}
li.task .nx-assign:disabled{opacity:.6;cursor:default}
li.task .nx-assign.done{background:#34c759;opacity:1}
@media print{li.task .nx-assign{display:none}}
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
  document.querySelectorAll("input.nx-todo").forEach(function (b) {
    b.disabled = false;
    b.onchange = function () {
      call("task", { i: b.getAttribute("data-i"), done: b.checked ? "1" : "0" }).then(function (r) {
        if (r.error) { b.checked = !b.checked; alert(r.error); }
      });
    };
  });
  root.querySelector(".nx-sharebtn").onclick = function () {
    pop.hidden = !pop.hidden; if (!pop.hidden) { q.focus(); load(); }
  };
  q.oninput = function () { clearTimeout(timer); timer = setTimeout(load, 500); };
  root.querySelector(".nx-copy").onclick = function () {
    call("copy").then(function (r) { say(r.error || "Copied. Paste it into any WhatsApp chat or group."); });
  };
  document.addEventListener("click", function (e) { if (!root.contains(e.target)) pop.hidden = true; });

  // --- "Preview & share client summary": build the client-facing page from
  // this meeting's Client Summary section and open it (it has its own Share).
  var clientBtn = document.querySelector(".nx-client");
  if (clientBtn) clientBtn.onclick = function () {
    var old = clientBtn.textContent; clientBtn.disabled = true; clientBtn.textContent = "Preparing…";
    call("client").then(function (r) {
      clientBtn.disabled = false; clientBtn.textContent = old;
      if (r && r.url) window.open(r.url, "_blank");
      else alert((r && r.error) || "Couldn't build the client summary.");
    });
  };

  // --- One-click ERP "Assign" on each action item, when Forklyft ERP is
  // connected. Creates the task (title + matched assignee + due) and opens it
  // in this browser; the user sets the project and the rest in Odoo.
  call("erp").then(function (r) {
    if (!r || !r.connected) return;
    var mon = { jan:0,feb:1,mar:2,apr:3,may:4,jun:5,jul:6,aug:7,sep:8,oct:9,nov:10,dec:11 };
    function pad(n){ return (n<10?"0":"")+n; }
    function parseDue(t){
      var m=(t||"").match(/(\d{1,2})\s+([A-Za-z]{3})/); if(!m) return "";
      var mo=mon[m[2].toLowerCase()]; if(mo==null) return "";
      var d=new Date(), dt=new Date(d.getFullYear(),mo,parseInt(m[1],10));
      if(dt.getTime()<d.getTime()-30*864e5) dt.setFullYear(d.getFullYear()+1); // roll to next year if clearly past
      return dt.getFullYear()+"-"+pad(dt.getMonth()+1)+"-"+pad(dt.getDate());
    }
    document.querySelectorAll("li.task").forEach(function(li){
      var tEl=li.querySelector(".t"); if(!tEl) return;
      var title=tEl.textContent.trim();
      var whoEl=li.querySelector(".chip.who"), who="";
      if(whoEl){ var c=whoEl.cloneNode(true), av=c.querySelector(".av"); if(av)av.remove(); who=c.textContent.trim(); }
      var dueEl=li.querySelector(".chip.due"), dueText=dueEl?dueEl.textContent.replace(/^Due\s*/,"").trim():"";
      var btn=document.createElement("button"); btn.type="button"; btn.className="nx-assign"; btn.textContent="Assign in ERP";
      btn.onclick=function(e){
        e.preventDefault(); e.stopPropagation();
        if(btn.classList.contains("done")){ if(btn._url) window.open(btn._url,"_blank"); return; }
        if(btn.disabled) return;
        btn.textContent="Creating…"; btn.disabled=true;
        call("assign",{ title:title, who:who, due:parseDue(dueText) }).then(function(r){
          btn.disabled=false;
          if(r && r.url){ btn._url=r.url; btn.classList.add("done"); btn.textContent="Open in ERP ✓"; window.open(r.url,"_blank"); }
          else { btn.textContent="Assign in ERP"; alert((r&&r.error)||"Couldn't create the task in ERP."); }
        });
      };
      (li.querySelector("label")||li).appendChild(btn);
    });
  });
})();</script><!--/nikxel-share-->
"""#
}
