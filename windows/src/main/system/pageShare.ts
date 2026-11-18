import { execFile } from "child_process";
import * as crypto from "crypto";
import * as fs from "fs";
import * as http from "http";
import * as path from "path";
import { cblog } from "../core/diag";
import { documentsRoot, nikxelPath, readText, writeAtomic } from "../core/paths";
import { Settings } from "../core/settings";
import { ChatbotEngine } from "../whatsapp/chatbotEngine";
import { ChromeWhatsApp } from "../whatsapp/chromeWhatsApp";
import * as PageEdit from "./pageEdit";

/// The Share button on summary pages. The page is a local file, so it can't
/// reach WhatsApp itself: it asks Nikxel over localhost, and Nikxel sends the
/// file from the WhatsApp window it already drives. "Copy" puts the file on
/// the clipboard, to paste into any chat or group by hand.
///
/// Any web page can call localhost, so every request carries a per-install
/// token that only pages Nikxel wrote contain, and only .html files under
/// Documents/nikxel can be sent.
export const port = 47120;

const tokenPath = nikxelPath("share_token");
let cachedToken: string | null = null;
function token(): string {
  if (cachedToken) return cachedToken;
  const saved = (readText(tokenPath) ?? "").trim();
  if (saved.length >= 32) return (cachedToken = saved);
  cachedToken = crypto.randomBytes(32).toString("hex");
  writeAtomic(tokenPath, cachedToken);
  return cachedToken;
}

/// Goes right before </body>. Marked, so a sent copy goes out without it.
/// `editable` adds the Edit button (PageEdit) beside Share.
export function widget(editable: boolean): string {
  return widgetTemplate.replace("__NIKXEL_TOKEN__", token())
    .replace("__NIKXEL_EDIT__", editable ? `<button class="nx-btn nx-edit" type="button">Edit</button>` : "");
}

export function strip(html: string): string {
  return html.replace(/<!--nikxel-share-->[\s\S]*?<!--\/nikxel-share-->/g, "");
}

// MARK: - Server

export function start(): void {
  token();
  const s = http.createServer((req, res) => {
    void handle(new URL(req.url ?? "/", "http://127.0.0.1")).then(body => {
      const json = JSON.stringify(body);
      res.writeHead(200, { "Content-Type": "application/json", "Access-Control-Allow-Origin": "*", "Content-Length": Buffer.byteLength(json) });
      res.end(json);
    });
  });
  s.on("error", () => cblog(`PageShare: port ${port} is busy — Share buttons won't work`));
  s.listen(port, "127.0.0.1");
}

// One send at a time: two would fight over the open chat.
let chain: Promise<unknown> = Promise.resolve();

async function handle(url: URL): Promise<Record<string, unknown>> {
  const q = (k: string) => url.searchParams.get(k);
  if (q("t") !== token()) return { error: "This page can only be shared from the PC that made it." };
  const file = allowedFile(q("path"));
  if (!file) return { error: "Only Nikxel's own pages can be shared." };

  switch (url.pathname) {
    case "/edit":
      if (!PageEdit.editable(file)) return { error: "This summary can't be edited." };
      PageEdit.showChat(file);
      return { ok: true };
    case "/version":
      try { return { v: fs.statSync(file).mtimeMs / 1000 }; } catch { return { v: 0 }; }
    case "/copy": {
      const out = nikxelPath("share", path.basename(file));
      try { writeAtomic(out, strip(fs.readFileSync(file, "utf8"))); } catch { return { error: "Couldn't read the page." }; }
      // A file on the clipboard, as Explorer's Copy puts it, so WhatsApp pastes the file.
      const ok = await new Promise<boolean>(resolve => execFile("powershell.exe",
        ["-NoProfile", "-NonInteractive", "-Command", `Set-Clipboard -LiteralPath '${out.replace(/'/g, "''")}'`],
        { windowsHide: true }, err => resolve(!err)));
      return ok ? { ok: true } : { error: "Couldn't put the file on the clipboard." };
    }
    case "/chats":
    case "/send": {
      if (!Settings.whatsappConnected) return { error: "WhatsApp isn't connected in Nikxel." };
      let result: Record<string, unknown> = {};
      const run = chain.then(() => ChatbotEngine.shared.withPollingHeld(async () => {
        if (url.pathname === "/chats") { result = { chats: await ChromeWhatsApp.searchChats(q("q") ?? "") }; return true; }
        const to = q("to") ?? "";
        if (!to) { result = { error: "Nothing to send." }; return true; }
        if (!(await ChromeWhatsApp.openChatBySearch(to))) { result = { error: `Couldn't open ${to}'s chat in WhatsApp.` }; return true; }
        const html = strip(fs.readFileSync(file, "utf8"));
        result = (await ChromeWhatsApp.sendFile(path.basename(file), Buffer.from(html, "utf8"), "text/html"))
          ? { ok: true } : { error: "WhatsApp didn't take the file." };
        cblog(`PageShare: ${path.basename(file)} → '${to}': ${result.ok ? "sent" : result.error}`);
        return true;
      }));
      chain = run.catch(() => {});
      await run;
      return result;
    }
    default:
      return { error: "Unknown request." };
  }
}

/// The page's own path, if it's an .html file Nikxel writes.
function allowedFile(p: string | null): string | null {
  if (!p) return null;
  try {
    const root = fs.realpathSync(path.join(documentsRoot(), "nikxel")) + path.sep;
    const file = fs.realpathSync(path.resolve(p));
    return file.toLowerCase().startsWith(root.toLowerCase()) && file.toLowerCase().endsWith(".html") ? file : null;
  } catch { return null; }
}

// MARK: - The button

/// Same markup as src/PageShare.swift.
const widgetTemplate = String.raw`<!--nikxel-share--><div id="nx-share">__NIKXEL_EDIT__<button class="nx-btn nx-sharebtn" type="button">Share</button><div class="nx-pop" hidden>
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
})();</script><!--/nikxel-share-->`;
