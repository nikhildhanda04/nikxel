import { execFile } from "child_process";
import * as crypto from "crypto";
import * as fs from "fs";
import * as http from "http";
import * as path from "path";
import { pathToFileURL } from "url";
import { cblog } from "../core/diag";
import { documentsRoot, nikxelPath, readText, writeAtomic } from "../core/paths";
import { Settings } from "../core/settings";
import { ChatbotEngine } from "../whatsapp/chatbotEngine";
import { ChromeWhatsApp } from "../whatsapp/chromeWhatsApp";
import * as PageEdit from "./pageEdit";
import * as ERP from "./erp";
import { NotePage } from "../recording/notePage";
import { DayPage } from "./dayPage";
import { CloudSync } from "./cloudSync";
import { DayLogger } from "./dayLogger";
import * as ProjectShare from "./projectShare";

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
/// `editable` adds the "tell Nikxel what to change" chat bar (PageEdit).
/// The inline chat bar docked at the bottom of an editable summary (replaces
/// the old Edit window). Same markup as chatBar in PageShare.swift.
const chatBar = String.raw`<div id="nx-chat"><div class="nxc-log" hidden><div class="nxc-head"><button type="button" class="nxc-undo" title="Undo the last change">↺ Undo</button><button type="button" class="nxc-clear" title="Clear the chat">Clear</button></div><div class="nxc-msgs"></div></div><form class="nxc-form"><button type="button" class="nxc-mic" title="Speak" aria-label="Speak"><svg viewBox="0 0 24 24" width="17" height="17" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="9" y="2" width="6" height="12" rx="3"/><path d="M5 10a7 7 0 0 0 14 0M12 17v5"/></svg></button><input class="nxc-in" placeholder="Tell Nikxel what to change…" autocomplete="off"><button class="nxc-send" title="Send" aria-label="Send">↑</button></form></div>`;

export function widget(editable: boolean): string {
  return widgetTemplate.replace("__NIKXEL_TOKEN__", token())
    .replace("__NIKXEL_CHAT__", editable ? chatBar : "");
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
      if (q("undo") === "1") {
        let ok = false;
        try { ok = PageEdit.undo(file); } catch { /* reported as nothing to undo */ }
        return { note: ok ? "Undone — back to before the last change." : "Nothing to undo." };
      }
      if (!q("text")?.trim()) return { error: "Nothing to change." };
      try { return { note: await PageEdit.apply(q("text")!, file) }; } catch (e) { return { error: (e as Error).message }; }
    case "/mic":
      // ponytail: the page runs in the user's browser and this server is GET-only, so
      // Windows has no way to hear it yet; record in a hidden window if people ask for it.
      return { error: "Voice isn't on Windows yet. Type it instead." };
    case "/task": {
      // A ticked box on a day page. The .md is what tomorrow's summary
      // and the morning card read, so "— done" there drops the task.
      const md = file.replace(/\.html$/i, ".md"), i = Number(q("i")), done = q("done") === "1";
      const text = readText(md), html = readText(file);
      const updated = text != null && Number.isInteger(i) ? DayPage.markTask(text, i, done) : null;
      if (updated == null || html == null) return { error: "Couldn't update that task." };
      try { writeAtomic(md, updated); } catch { return { error: "Couldn't update that task." }; }
      try { writeAtomic(file, html.replace(new RegExp(`data-i="${i}"( checked)?`), `data-i="${i}"` + (done ? " checked" : ""))); } catch { /* the .md has it */ }
      return { ok: true };
    }
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
    case "/client": {
      // Render the client-facing page from the meeting's "## Client Summary"
      // section and hand back its file URL. The page carries its own Share
      // buttons, so the user previews it, then sends it.
      const mdPath = file.replace(/\.html$/i, ".md");
      const md = readText(mdPath);
      const clientMd = md ? NotePage.clientMarkdown(md) : null;
      if (!clientMd) return { error: "This summary has no client version." };
      const clientFile = file.replace(/\.html$/i, ".client.html");
      try { writeAtomic(clientFile, NotePage.html(clientMd)); }
      catch { return { error: "Couldn't build the client summary." }; }
      return { url: pathToFileURL(clientFile).href };
    }
    case "/projects":
    case "/share-project":
      // A meeting page's Share to project dialog (list + exact body), then its Send.
      return ProjectShare.handle(url.pathname === "/projects" ? null : q("project") ?? "", file);
    case "/dashboard-state":
    case "/dashboard": {
      // The daily page's Send bar. <stem>.sent.json beside it remembers what was crossed out.
      if (path.basename(path.dirname(file)) !== "daily") return { error: "Only a daily summary can be sent to the dashboard." };
      const stem = path.basename(file).replace(/\.html$/i, ""), sentFile = path.join(path.dirname(file), `${stem}.sent.json`);
      if (url.pathname === "/dashboard-state") {
        let sent: { skip?: string[]; sentAt?: number } = {};
        try { sent = JSON.parse(readText(sentFile) ?? "{}"); } catch { /* never sent */ }
        return { paired: CloudSync.token() !== null, skip: sent.skip ?? [], sentAt: sent.sentAt ?? null };
      }
      if (!CloudSync.token()) return { error: "Connect Nikxel to the dashboard first (menu → Connect to Dashboard…)" };
      const md = readText(file.replace(/\.html$/i, ".md"));
      if (md == null) return { error: "Couldn't read this day's summary." };
      const skip = (q("skip") ?? "").split(",").filter(Boolean);
      const resend = fs.existsSync(sentFile);
      if (!resend && CloudSync.dayItems(md).items.every(i => skip.includes(i.id))) return { error: "Nothing left to send." };
      // Measured tiles so the dashboard shows the same numbers as this page.
      const stats = CloudSync.statsFromMarkers(md);
      const s = DayLogger.current?.dayStats(new Date(stem + "T00:00"));
      if (s) {
        if (stats.computer === undefined && s.activeSeconds >= 60) stats.computer = Math.round(s.activeSeconds / 60);
        if (stats.coding === undefined && s.codingSeconds >= 60) stats.coding = Math.round(s.codingSeconds / 60);
        if (stats.meetings === undefined && s.meetings > 0) stats.meetings = s.meetings;
        if (stats.messages === undefined && s.messages > 0) stats.messages = s.messages;
      }
      if (!(await CloudSync.pushDay(md, stem, new Set(skip), Object.keys(stats).length ? stats : null, undefined, resend))) return { error: "Couldn't reach the dashboard. Try again." };
      try { writeAtomic(sentFile, JSON.stringify({ skip, sentAt: Date.now() / 1000 })); } catch { /* sent anyway */ }
      return { ok: true };
    }
    case "/erp":
      // Just whether Assign buttons should show. Matching + create happen
      // server-side on /assign, so the page needs no roster.
      return { connected: ERP.isConnected() };
    case "/assign": {
      if (!ERP.isConnected()) return { error: "Connect Forklyft ERP in Nikxel first." };
      if (!(await ERP.hasLiveSession())) return { error: "Your ERP session has ended. Reconnect Forklyft ERP from the Nikxel menu, then try again." };
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
      if (!html || !html.includes("<!--nikxel-share-->") || html.includes("<!--nxwa-->")) continue;
      const block = widget(html.includes("nx-edit") || html.includes("nx-chat"));
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
const widgetTemplate = String.raw`<!--nikxel-share--><!--nxwa--><div id="nx-share"><button class="nx-btn nx-sharebtn" type="button">Share</button><div class="nx-pop" hidden>
<button class="nx-copy" type="button">Copy file</button><div class="nx-or">or send on WhatsApp to</div>
<input class="nx-q" placeholder="Search a chat or contact"><div class="nx-list"></div><div class="nx-msg"></div></div></div>
__NIKXEL_CHAT__
<style>
#nx-share{position:fixed;right:20px;bottom:20px;z-index:99;font:14px/1.4 system-ui,-apple-system,"Segoe UI",sans-serif;color:#1d1d1f}
#nx-share .nx-btn{background:#1d1d1f;color:#fff;border:0;border-radius:999px;padding:10px 18px;font:inherit;font-weight:600;cursor:pointer;box-shadow:0 4px 16px rgba(0,0,0,.18)}
#nx-chat{position:fixed;left:50%;transform:translateX(-50%);bottom:18px;width:min(720px,calc(100vw - 32px));z-index:98;font:14px/1.45 system-ui,-apple-system,"Segoe UI",sans-serif}
#nx-chat .nxc-log{max-height:44vh;overflow:auto;margin-bottom:8px;background:rgba(255,255,255,.66);-webkit-backdrop-filter:blur(20px) saturate(1.7);backdrop-filter:blur(20px) saturate(1.7);border:1px solid rgba(0,0,0,.08);border-radius:18px;box-shadow:0 12px 44px rgba(0,0,0,.18)}
#nx-chat .nxc-log[hidden]{display:none}
#nx-chat .nxc-head{position:sticky;top:0;display:flex;justify-content:space-between;gap:8px;padding:8px 12px;background:inherit;border-bottom:1px solid rgba(0,0,0,.06)}
#nx-chat .nxc-head button{border:0;background:none;color:#6e6e73;font:inherit;font-size:12px;cursor:pointer;padding:3px 8px;border-radius:7px}
#nx-chat .nxc-head button:hover{background:rgba(0,0,0,.06);color:#1d1d1f}
#nx-chat .nxc-msgs{display:flex;flex-direction:column;gap:8px;padding:12px}
#nx-chat .nxc-msg{max-width:85%;padding:8px 12px;border-radius:14px;white-space:pre-wrap;font-size:13.5px}
#nx-chat .nxc-me{align-self:flex-end;background:#1d1d1f;color:#fff;border-bottom-right-radius:5px}
#nx-chat .nxc-bot{align-self:flex-start;background:rgba(0,0,0,.06);color:#1d1d1f;border-bottom-left-radius:5px}
#nx-chat .nxc-form{display:flex;align-items:center;gap:4px;padding:5px 5px 5px 8px;background:rgba(255,255,255,.58);-webkit-backdrop-filter:blur(20px) saturate(1.7);backdrop-filter:blur(20px) saturate(1.7);border:1px solid rgba(0,0,0,.1);border-radius:999px;box-shadow:0 8px 30px rgba(0,0,0,.16)}
#nx-chat .nxc-in{flex:1;min-width:0;border:0;outline:0;background:transparent;font:inherit;color:#1d1d1f;padding:9px 6px}
#nx-chat .nxc-mic,#nx-chat .nxc-send{width:34px;height:34px;border:0;border-radius:50%;cursor:pointer;flex:none;display:grid;place-items:center}
#nx-chat .nxc-mic{background:transparent;color:#6e6e73}
#nx-chat .nxc-mic:hover{background:rgba(0,0,0,.08)}
#nx-chat .nxc-mic.rec{background:#ff3b30;color:#fff;animation:nxc-pulse 1.3s infinite}
#nx-chat .nxc-send{background:#5e5ce6;color:#fff;font:17px/1 system-ui}
#nx-chat .nxc-send:disabled{opacity:.5;cursor:default}
@keyframes nxc-pulse{0%{box-shadow:0 0 0 0 rgba(255,59,48,.5)}100%{box-shadow:0 0 0 10px rgba(255,59,48,0)}}
body.nx-has-chat{padding-bottom:104px}
@media (prefers-color-scheme:dark){
#nx-chat .nxc-log{background:rgba(28,28,32,.62);border-color:rgba(255,255,255,.1)}
#nx-chat .nxc-head{border-bottom-color:rgba(255,255,255,.08)}
#nx-chat .nxc-head button{color:#a0a0a8}
#nx-chat .nxc-head button:hover{background:rgba(255,255,255,.1);color:#fff}
#nx-chat .nxc-bot{background:rgba(255,255,255,.12);color:#f5f5f7}
#nx-chat .nxc-form{background:rgba(36,36,40,.55);border-color:rgba(255,255,255,.14)}
#nx-chat .nxc-in{color:#f5f5f7}
#nx-chat .nxc-mic{color:#a0a0a8}
#nx-chat .nxc-mic:hover{background:rgba(255,255,255,.1)}
}
@media print{#nx-chat{display:none}}
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
  // Inline "tell Nikxel what to change" bar (replaces the old Edit dialog).
  // Talks to /edit over the same bridge; the chat log survives the reload that
  // shows each applied change, via sessionStorage.
  var chat = document.getElementById("nx-chat");
  if (chat) {
    document.body.classList.add("nx-has-chat");
    var clog = chat.querySelector(".nxc-log"), cmsgs = chat.querySelector(".nxc-msgs"), cin = chat.querySelector(".nxc-in");
    var csend = chat.querySelector(".nxc-send"), cmic = chat.querySelector(".nxc-mic");
    var cundo = chat.querySelector(".nxc-undo"), cclear = chat.querySelector(".nxc-clear"), LK = "nx-chatlog";
    var cbubble = function (role, text) {
      var d = document.createElement("div"); d.className = "nxc-msg " + (role === "me" ? "nxc-me" : "nxc-bot");
      d.textContent = text; cmsgs.appendChild(d); clog.hidden = false; clog.scrollTop = clog.scrollHeight; return d;
    };
    var cstore = function (role, text) { try { var a = JSON.parse(sessionStorage.getItem(LK) || "[]"); a.push([role, text]); sessionStorage.setItem(LK, JSON.stringify(a.slice(-20))); } catch (e) {} };
    try { JSON.parse(sessionStorage.getItem(LK) || "[]").forEach(function (m) { cbubble(m[0], m[1]); }); } catch (e) {}
    var cbusy = false, rec = false;
    var csync = function () { csend.disabled = cbusy || !cin.value.trim(); cin.disabled = cbusy; cmic.disabled = cbusy; };
    var creload = function () { setTimeout(function () { location.reload(); }, 600); };
    var crun = function (text) {
      cbubble("me", text); cstore("me", text);
      var w = cbubble("bot", "…"); cbusy = true; csync();
      call("edit", { text: text }).then(function (r) {
        var note = (r && (r.note || r.error)) || "Something went wrong.";
        w.textContent = note; cstore("bot", note); cbusy = false; csync();
        if (r && r.note) creload();   // applied — reload to show it; the log survives in sessionStorage
      });
    };
    chat.querySelector(".nxc-form").onsubmit = function (e) { e.preventDefault(); var t = cin.value.trim(); if (!t || cbusy) return; cin.value = ""; csync(); crun(t); };
    cin.oninput = csync;
    cundo.onclick = function () {
      if (cbusy) return; cbusy = true; csync();
      call("edit", { undo: "1" }).then(function (r) {
        var note = (r && (r.note || r.error)) || "Nothing to undo."; cbubble("bot", note); cstore("bot", note);
        cbusy = false; csync(); if (r && r.note && r.note.indexOf("Nothing") < 0) creload();
      });
    };
    cclear.onclick = function () { cmsgs.innerHTML = ""; clog.hidden = true; try { sessionStorage.removeItem(LK); } catch (e) {} };
    // Voice: recorded and transcribed on-device by Nikxel (no audio leaves the machine).
    cmic.onclick = function () {
      if (cbusy) return;
      if (!rec) {
        call("mic", { do: "start" }).then(function (r) {
          if (r && r.ok) { rec = true; cmic.classList.add("rec"); cin.placeholder = "Listening… tap the mic to stop"; }
          else cbubble("bot", (r && r.error) || "Couldn't use the microphone.");
        });
        return;
      }
      rec = false; cmic.classList.remove("rec"); cin.placeholder = "Tell Nikxel what to change…";
      cbusy = true; csync();
      call("mic", { do: "stop" }).then(function (r) {
        cbusy = false; csync();
        var heard = (r && r.text) || "";
        if (heard) { cin.value = (cin.value ? cin.value + " " : "") + heard; cin.focus(); csync(); }
      });
    };
    csync();
    // On open: a quick hand-drawn arrow from the title down to the chat bar, so
    // people notice they can edit. Draws in, holds, fades out (~2.5s total).
    function cHint() {
      try {
        var titleEl = document.querySelector(".date") || document.querySelector("h1") || document.querySelector("main");
        if (!titleEl) return;
        var tr = titleEl.getBoundingClientRect(), cr = chat.getBoundingClientRect(), NS = "http://www.w3.org/2000/svg";
        var sx = tr.left, sy = tr.bottom + 4, ex = cr.left + 26, ey = cr.top - 14;
        var leftX = Math.max(8, Math.min(sx, ex) - 90);    // bow well out into the left gutter
        var svg = document.createElementNS(NS, "svg");
        svg.setAttribute("width", innerWidth); svg.setAttribute("height", innerHeight);
        svg.style.cssText = "position:fixed;inset:0;z-index:97;pointer-events:none";
        svg.innerHTML = '<defs><marker id="nxc-ah" markerWidth="10" markerHeight="10" refX="6.5" refY="5" orient="auto"><path d="M0,0 L10,5 L0,10 z" fill="#5e5ce6"/></marker></defs>';
        var p = document.createElementNS(NS, "path");
        p.setAttribute("d", "M " + sx + " " + sy + " C " + leftX + " " + (sy + 50) + " " + leftX + " " + (ey - 70) + " " + ex + " " + ey);
        p.setAttribute("fill", "none"); p.setAttribute("stroke", "#5e5ce6"); p.setAttribute("stroke-width", "3");
        p.setAttribute("stroke-linecap", "round"); p.setAttribute("marker-end", "url(#nxc-ah)");
        svg.appendChild(p); document.body.appendChild(svg);
        var cap = document.createElement("div"); cap.textContent = "Edit anything here";
        cap.style.cssText = "position:fixed;left:" + ex + "px;top:" + (ey - 46) + "px;z-index:97;pointer-events:none;background:#5e5ce6;color:#fff;font:600 12px/1 system-ui,-apple-system,sans-serif;padding:6px 11px;border-radius:999px;white-space:nowrap;box-shadow:0 6px 20px rgba(94,92,230,.45)";
        document.body.appendChild(cap);
        var reduce = matchMedia("(prefers-reduced-motion: reduce)").matches, len = p.getTotalLength();
        p.style.strokeDasharray = len; p.style.strokeDashoffset = reduce ? 0 : len;
        if (!reduce) p.animate([{ strokeDashoffset: len }, { strokeDashoffset: 0 }], { duration: 850, fill: "forwards", easing: "ease-out" });
        cap.animate([{ opacity: 0, transform: "translateY(6px)" }, { opacity: 1, transform: "translateY(0)" }], { duration: 400, delay: reduce ? 0 : 500, fill: "both", easing: "ease-out" });
        setTimeout(function () {
          [svg, cap].forEach(function (el) { var f = el.animate([{ opacity: 1 }, { opacity: 0 }], { duration: 500, fill: "forwards" }); f.onfinish = function () { el.remove(); }; });
        }, 2500);
      } catch (e) {}
    }
    setTimeout(cHint, 500);   // let layout and fonts settle first
  }
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

  // --- "Share to project": pick one of your dashboard projects, see exactly
  // what goes (the minutes minus the client summary), then Send.
  var projBtn = document.querySelector(".nx-project");
  if (projBtn) projBtn.onclick = function () {
    var dlg = document.createElement("dialog");
    dlg.style.cssText = "width:min(560px,calc(100vw - 32px));box-sizing:border-box;border:0;border-radius:16px;padding:20px;font:14px/1.45 system-ui,-apple-system,'Segoe UI',sans-serif;color:#1d1d1f;background:#fff;box-shadow:0 20px 60px rgba(0,0,0,.3)";
    var btnCss = "border:0;border-radius:10px;padding:9px 16px;font:600 14px/1 system-ui,-apple-system,'Segoe UI',sans-serif;cursor:pointer;";
    dlg.onclose = function () { dlg.remove(); };
    document.body.appendChild(dlg); dlg.textContent = "Loading your projects…"; dlg.showModal();
    function el(tag, css, text) { var e = document.createElement(tag); if (css) e.style.cssText = css; if (text != null) e.textContent = text; return e; }
    function button(text, primary, onclick) {
      var b = el("button", btnCss + (primary ? "background:#1d1d1f;color:#fff" : "background:#f0f0f3;color:#1d1d1f"), text);
      b.type = "button"; b.onclick = onclick; return b;
    }
    function done(text) {
      dlg.textContent = ""; dlg.appendChild(el("p", "margin:0 0 16px", text));
      var row = el("div", "display:flex;justify-content:flex-end"); row.appendChild(button("Close", true, function () { dlg.close(); }));
      dlg.appendChild(row);
    }
    call("projects").then(function (r) {
      if (!r || r.error) return done((r && r.error) || "Couldn't reach Nikxel.");
      if (!r.paired) return done("Connect Nikxel to the dashboard first");
      if (!r.projects || !r.projects.length) return done("You're not on any project yet. Create one on the dashboard.");
      dlg.textContent = "";
      dlg.appendChild(el("h3", "margin:0 0 10px;font-size:16px", "Share to project"));
      r.projects.forEach(function (p, i) {
        var lab = el("label", "display:flex;gap:8px;align-items:center;padding:5px 2px;cursor:pointer"), radio = el("input");
        radio.type = "radio"; radio.name = "nx-proj"; radio.value = p.id; radio.checked = i === 0; radio._name = p.name;
        lab.appendChild(radio); lab.appendChild(el("span", "", p.name)); dlg.appendChild(lab);
      });
      dlg.appendChild(el("div", "margin:12px 0 6px;color:#6e6e73;font-size:12px", "Exactly what will be sent"));
      dlg.appendChild(el("pre", "max-height:40vh;overflow:auto;white-space:pre-wrap;margin:0;padding:10px 12px;background:#f5f5f7;border-radius:10px;font:12px/1.5 ui-monospace,Menlo,Consolas,monospace", r.body));
      var msg = el("p", "min-height:1.2em;margin:10px 0;color:#6e6e73;font-size:12px");
      var row = el("div", "display:flex;justify-content:flex-end;gap:8px");
      var send = button("Send", true, function () {
        var pick = dlg.querySelector("input[name=nx-proj]:checked");
        if (!pick) { msg.textContent = "Pick a project."; return; }
        send.disabled = true; msg.textContent = "Sending…";
        call("share-project", { project: pick.value }).then(function (s) {
          if (s && s.ok) done("Shared to " + pick._name);
          else { send.disabled = false; msg.textContent = (s && s.error) || "Couldn't share it."; }
        });
      });
      row.appendChild(button("Cancel", false, function () { dlg.close(); })); row.appendChild(send);
      dlg.appendChild(msg); dlg.appendChild(row);
    });
  };

  // --- Daily page: cross out what stays private, then send the day to the
  // org dashboard. What was crossed out comes back from <day>.sent.json.
  var bar = document.querySelector(".nx-send");
  if (bar) {
    var sendBtn = bar.querySelector("button"), sentMsg = bar.querySelector(".nx-sent");
    var hhmm = function (s) { var d = new Date(s * 1000); return ("0" + d.getHours()).slice(-2) + ":" + ("0" + d.getMinutes()).slice(-2); };
    call("dashboard-state").then(function (r) {
      if (!r || r.error) return;
      bar.hidden = false;
      document.querySelectorAll("[data-id]").forEach(function (el) {
        if ((r.skip || []).indexOf(el.getAttribute("data-id")) >= 0) el.classList.add("x");
      });
      if (r.sentAt) sentMsg.textContent = "Sent " + hhmm(r.sentAt);
    });
    document.addEventListener("click", function (e) {
      if (bar.hidden || e.target.closest("a, input, button")) return;
      var item = e.target.closest("[data-id]"); if (!item) return;
      e.preventDefault();   // a click on a task's text crosses it out rather than ticking it
      item.classList.toggle("x");
    });
    sendBtn.onclick = function () {
      var skip = [].map.call(document.querySelectorAll("[data-id].x"), function (el) { return el.getAttribute("data-id"); });
      sendBtn.disabled = true; sentMsg.textContent = "Sending…";
      call("dashboard", { skip: skip.join(",") }).then(function (r) {
        sendBtn.disabled = false;
        sentMsg.textContent = (r && r.error) || "Sent ✓ " + hhmm(Date.now() / 1000);
      });
    };
  }

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
