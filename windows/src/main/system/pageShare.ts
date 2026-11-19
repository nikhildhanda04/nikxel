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
import * as ERP from "./erp";

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
  setImmediate(migrateWidgets); // give existing pages the Assign button
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
    case "/erp":
      // Just whether Assign buttons should show. Matching + create happen
      // server-side on /assign, so the page needs no roster.
      return { connected: ERP.isConnected() };
    case "/assign": {
      if (!ERP.isConnected()) return { error: "Connect Forklyft ERP in Nikxel first." };
      // The page sends the full action-item text; we make a short title and a
      // context-rich description, since the assignee may not have been in the
      // meeting. Only the title is required in Odoo.
      const item = q("title");
      if (!item) return { error: "No task text." };
      const who = q("who") ?? "";
      const uid = who ? (ERP.matchUser(who, await ERP.assignableUsers())?.id ?? null) : null;
      const due = q("due");
      const deadline = due ? `${due} 17:00:00` : null; // date → datetime
      const title = ERP.shortTitle(item);
      const mdPath = file.replace(/\.html$/i, ".md");
      // Prefer the rich brief Nikxel already wrote for software tasks; fall
      // back to the plain task + meeting origin for the rest.
      const desc = ERP.briefFromAgentPrompts(item, mdPath) ?? ERP.taskDescription(item, meetingContext(file));
      const tid = await ERP.createTask(title, desc, uid, deadline);
      if (tid == null) return { error: "ERP didn't create the task." };
      cblog(`ERP: created task ${tid} — ${title.slice(0, 60)}`);
      return { url: ERP.taskURL(tid) };
    }
    default:
      return { error: "Unknown request." };
  }
}

/// A one-line meeting context for a task description: the summary headline and
/// the meeting date. Mirrors PageShare.meetingContext in src/PageShare.swift.
function meetingContext(file: string): string {
  const stem = path.basename(file).replace(/\.[^.]+$/, ""); // 2026-11-12-103105
  const date = stem.slice(0, 10);
  let headline = "";
  const html = readText(file);
  if (html) {
    const m = html.match(/<h1[^>]*>[\s\S]*?<\/h1>/);
    if (m) headline = m[0].replace(/<[^>]+>/g, "").trim();
  }
  if (!headline) return `Came out of a team meeting on ${date}.`;
  return `Came out of a team meeting on ${date}: ${headline}`;
}

/// Re-inject the current widget into pages Nikxel already wrote, so old
/// summaries gain new buttons (Assign). Idempotent via the version marker.
function migrateWidgets(): void {
  const root = path.join(documentsRoot(), "nikxel");
  const walk = (d: string) => {
    let entries: fs.Dirent[];
    try { entries = fs.readdirSync(d, { withFileTypes: true }); } catch { return; }
    for (const e of entries) {
      const full = path.join(d, e.name);
      if (e.isDirectory()) { walk(full); continue; }
      if (!e.name.toLowerCase().endsWith(".html")) continue;
      const html = readText(full);
      if (!html || !html.includes("<!--nikxel-share-->") || html.includes("<!--nxw3-->")) continue;
      const block = widget(html.includes("nx-edit"));
      // Replacer function so "$1" inside the block isn't treated specially.
      const out = html.replace(/<!--nikxel-share-->[\s\S]*?<!--\/nikxel-share-->/, () => block);
      try { writeAtomic(full, out); } catch { /* leave the page as it was */ }
    }
  };
  walk(root);
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
const widgetTemplate = String.raw`<!--nikxel-share--><!--nxw3--><div id="nx-share">__NIKXEL_EDIT__<button class="nx-btn nx-sharebtn" type="button">Share</button><div class="nx-pop" hidden>
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
  root.querySelector(".nx-sharebtn").onclick = function () {
    pop.hidden = !pop.hidden; if (!pop.hidden) { q.focus(); load(); }
  };
  q.oninput = function () { clearTimeout(timer); timer = setTimeout(load, 500); };
  root.querySelector(".nx-copy").onclick = function () {
    call("copy").then(function (r) { say(r.error || "Copied. Paste it into any WhatsApp chat or group."); });
  };
  document.addEventListener("click", function (e) { if (!root.contains(e.target)) pop.hidden = true; });

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
      if(whoEl){ var cl=whoEl.cloneNode(true), av=cl.querySelector(".av"); if(av)av.remove(); who=cl.textContent.trim(); }
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
})();</script><!--/nikxel-share-->`;
