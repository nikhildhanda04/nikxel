import * as PageShare from "./pageShare";
import { escapeHtml as esc, favicon, fmt, inline as inl, isNone, parseLocalDate } from "../recording/markdown";
import { anchor, count, generic, isEmpty, lead, parse, Section } from "../recording/notePage";
import type { DayStats } from "./dayLogger";
import { CloudSync } from "./cloudSync";

/// Port of DayPage.swift.
///
/// The end-of-day summary as a page: the meeting note's sibling, but dusk
/// instead of daylight (it lands at 10pm). A night-sky header with the day's
/// takeaway, the day's numbers as tiles, the work as a timeline, meetings as
/// cards, chat tasks with a done/open status, and the lighter sections side
/// by side. Unknown sections fall back to NotePage's generic layout.
/// The Sunday week in review uses the same page at sunrise (`morning`).

/// "… — open" / "… — done." at the end of a bullet, as the prompt asks for chat tasks.
const STATUS = /\s+[—–-]\s*\**(done|open|unclear)\**\.?\s*$/i;
/// "10:30 — …", "**00:13**: …", "**10:31, Standup**:" at the start of a meeting bullet.
const LEAD_TIME = /^(\*\*)?(~?\d{1,2}(?::\d{2})?\s?(?:am|pm)?)(\*\*)?\s*[,—–:-]\s*/i;

/// A bullet and the bullets indented under it. NotePage.parse flattens
/// nesting, and day summaries group details under a project or meeting.
interface Item { text: string; kids: Item[] }

function tree(markdown: string, key: string): Item[] {
  const roots: Item[] = [];
  const stack: { indent: number; item: Item }[] = [];
  let inside = false;
  for (const raw of markdown.split(/\r\n|\r|\n/)) {
    if (raw.startsWith("## ")) { inside = raw.slice(3).trim().toLowerCase() === key; stack.length = 0; continue; }
    const m = inside ? /^(\s*)[-*] (.*)$/.exec(raw) : null;
    if (!m || isNone(m[2])) continue;
    const item: Item = { text: m[2].trim(), kids: [] };
    const indent = m[1].replace(/\t/g, "  ").length;
    while (stack.length && stack[stack.length - 1].indent >= indent) stack.pop();
    (stack.length ? stack[stack.length - 1].item.kids : roots).push(item);
    stack.push({ indent, item });
  }
  return roots;
}

/// The day as dayItems will send it, plus the dialog that previews it the
/// way the dashboard shows it (Going / Not going). Daily pages only.
function previewBlock(markdown: string): string {
  const day = CloudSync.dayItems(markdown);
  return `<script type="application/json" id="nx-day">${JSON.stringify(day).replace(/</g, "\\u003c")}</script>\n`
    + previewDialog + "\n<script>" + previewJS + "</script>";
}

/// Same markup and script in src/DayPage.swift.
const previewDialog = String.raw`<dialog class="nx-pv" aria-label="Preview"><div class="pv-head"><b>How your day will look on the dashboard</b><small>Ticked items are sent; untick anything you don't want to share. You can also click items on the page to cross them out.</small><div class="pv-tabs"></div></div><div class="pv-body"></div><div class="pv-foot"><button type="button" class="pv-close">Keep editing</button><button type="button" class="pv-send">Send to dashboard</button></div></dialog>`;

const previewJS = String.raw`
(function () {
  // Preview: the day as the dashboard will show it. Ticked = it goes; unticking
  // crosses the item out on the page too, and the other way round.
  var bar = document.querySelector(".nx-send"), dlg = document.querySelector(".nx-pv"), src = document.getElementById("nx-day");
  if (!bar || !dlg || !src) return;
  var day = JSON.parse(src.textContent), show = "going";
  var T = { coding: "Coding", shipped: "Shipped", meeting: "Meeting", research: "Research", learning: "Learning", writing: "Writing", review: "Review", planning: "Planning", comms: "Comms", other: "Other" };
  function esc(s) { return String(s).replace(/[&<>"]/g, function (c) { return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]; }); }
  function dur(m) { var h = Math.floor(m / 60); return h && m % 60 ? h + "h " + (m % 60) + "m" : h ? h + "h" : m + "m"; }
  function type(t) { return T[t] ? t : "other"; }
  function crossed() { var x = {}; document.querySelectorAll("main [data-id].x").forEach(function (el) { x[el.getAttribute("data-id")] = 1; }); return x; }
  function tick(id, going) { return '<input type="checkbox" class="pv-tick" data-tick="' + esc(id) + '"' + (going ? " checked" : "") + ' aria-label="Send this">'; }
  function item(i, going) {
    var t = type(i.type);
    return '<li><label class="pv-row">' + tick(i.id, going) + '<span class="pv-chip pv-' + t + '">' + T[t] + '</span>'
      + (i.project ? '<span class="pv-proj">' + esc(i.project) + '</span>' : '')
      + '<span class="pv-what">' + esc(i.what) + '</span>' + (i.minutes ? '<span class="pv-min">' + dur(i.minutes) + '</span>' : '') + '</label>'
      + (i.details.length ? '<details><summary>' + i.details.length + ' more</summary><ul>' + i.details.map(function (d) { return '<li>' + esc(d) + '</li>'; }).join("") + '</ul></details>' : '')
      + '</li>';
  }
  function groups(list, going) {
    var order = [];
    list.forEach(function (i) { if (order.indexOf(i.section) < 0) order.push(i.section); });
    return order.map(function (s) {
      return '<h3>' + esc(s.charAt(0).toUpperCase() + s.slice(1)) + '</h3><ul class="pv-items">'
        + list.filter(function (i) { return i.section === s; }).map(function (i) { return item(i, going); }).join("") + '</ul>';
    }).join("");
  }
  function render() {
    var x = crossed(), going = day.items.filter(function (i) { return !x[i.id]; }), gone = day.items.filter(function (i) { return x[i.id]; });
    var head = day.headline && !x.headline, mins = {}, total = 0, date = document.querySelector(".date");
    going.forEach(function (i) { if (i.minutes) { var t = type(i.type); mins[t] = (mins[t] || 0) + i.minutes; total += i.minutes; } });
    var nGoing = going.length + (head ? 1 : 0), nGone = gone.length + (day.headline && x.headline ? 1 : 0);
    dlg.querySelector(".pv-tabs").innerHTML =
      '<button type="button" data-v="going" aria-pressed="' + (show === "going") + '">Going · ' + nGoing + '</button>'
      + '<button type="button" data-v="gone" aria-pressed="' + (show === "gone") + '">Not going · ' + nGone + '</button>';
    var html;
    if (show === "going") {
      html = !nGoing ? '<p class="pv-empty">Nothing will be shared.</p>'
        : '<div class="pv-card"><p class="pv-date">' + esc(date ? date.textContent : "") + '</p>'
          + (head ? '<label class="pv-row pv-hl">' + tick("headline", true) + '<span>' + esc(day.headline) + '</span></label>' : '')
          + (total ? '<div class="pv-bar" aria-hidden="true">' + Object.keys(mins).map(function (t) { return '<i class="pv-' + t + '" style="flex:' + mins[t] + '"></i>'; }).join("") + '</div>'
            + '<p class="pv-legend">' + Object.keys(mins).map(function (t) { return dur(mins[t]) + " " + T[t].toLowerCase(); }).join(" · ") + '</p>' : '')
          + groups(going, true) + '</div>';
    } else {
      html = !nGone ? '<p class="pv-empty">Nothing is unticked — everything goes.</p>'
        : '<div class="pv-gone">' + (day.headline && x.headline ? '<h3>Summary</h3><label class="pv-row">' + tick("headline", false) + '<span class="pv-what">' + esc(day.headline) + '</span></label>' : '')
          + groups(gone, false) + '</div>';
    }
    dlg.querySelector(".pv-body").innerHTML = html;
  }
  bar.querySelector(".nx-prev").onclick = function () { show = "going"; render(); dlg.showModal(); };
  dlg.addEventListener("change", function (e) {
    var id = e.target.getAttribute("data-tick"); if (!id) return;
    document.querySelectorAll("main [data-id]").forEach(function (el) { if (el.getAttribute("data-id") === id) el.classList.toggle("x", !e.target.checked); });
    render();
  });
  dlg.addEventListener("click", function (e) {
    var b = e.target.closest("button"); if (!b) return;
    if (b.dataset.v) { show = b.dataset.v; render(); }
    else if (b.classList.contains("pv-close")) dlg.close();
    else if (b.classList.contains("pv-send")) { dlg.close(); bar.querySelector("button").click(); bar.scrollIntoView({ block: "center" }); }
  });
})();
`;

/// `daily` (the 10pm page only): each sent item gets its CloudSync id as data-id, plus the Send bar.
function html(markdown: string, stats: DayStats | null = null, morning = false, daily = false): string {
  const preview = daily ? previewBlock(markdown) : "";
  markdown = markdown.replace(/^(\s*[-*] )\[[a-z]+\] /gm, "$1").replace(/^(\s*[-*] )\[\[[^\]\n]+?\]\][ \t]*/gm, "$1"); // the type and project tags are for the dashboard
  const { title, sections } = parse(markdown);
  const find = (k: string) => sections.find(s => s.key === k);

  let body = "";
  const empty: string[] = [];
  const side: Section[] = [];
  for (const s of sections) {
    if (s.key === "summary") continue;
    if (isEmpty(s)) { empty.push(s.title); continue; }
    if (s.key === "browsing & reading" || s.key === "other") { side.push(s); continue; }
    const items = tree(markdown, s.key), id = ider(s.key, daily);
    switch (s.key) {
      case "what you worked on": body += section(s, items.length, timeline(items, id) + paras(s)); break;
      case "meetings": body += section(s, items.length, meetings(items, id) + paras(s)); break;
      case "whatsapp": case "slack": body += section(s, items.length, statusList(items, id) + paras(s)); break;
      case "open tasks": body += section(s, items.length, todoList(items, id) + paras(s)); break;
      default: body += section(s, count(s), plainOrGeneric(s, markdown, daily));
    }
  }
  if (side.length) {
    body += `<div class="pair">${side.map(s => `<section id="${anchor(s.title)}" class="sec panel"><h2>${esc(s.title)}</h2>${plainOrGeneric(s, markdown, daily)}</section>`).join("")}</div>\n`;
  }
  if (empty.length) body += `<p class="empty">Quiet on ${empty.map(esc).join(" · ")}.</p>\n`;

  return `<!doctype html>
<html lang="en"><head><meta charset="utf-8">${favicon}
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<title>${esc(title || (morning ? "Week in review" : "Day in review"))}</title>
<link rel="preconnect" href="https://fonts.googleapis.com"><link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=DM+Mono:wght@400;500&family=DM+Sans:opsz,wght@9..40,400;9..40,500;9..40,600;9..40,700&family=Fraunces:opsz,wght@9..144,500;9..144,600;9..144,800;9..144,900&display=swap">
<style>${css}${morning ? morningCSS : ""}</style></head><body>
<main>
${hero(title, find("summary"), morning, daily)}
${stats ? tiles(stats) : ""}
${body}
${daily ? `<div class="nx-send" hidden><p>Cross out anything you don't want to share, then send.</p><button>Send to dashboard</button><button class="nx-prev">Preview what's shared</button><span class="nx-sent"></span></div>` : ""}
${preview}
<footer>Written by Nikxel from ${morning ? "this week's daily summaries" : "today's activity"} on this computer. Nothing here left it.</footer>
</main>
${PageShare.widget(false)}</body></html>`;
}

/// ` data-id="…"` for a top-level bullet: the id dayItems gives that same bullet, so the
/// page and the sent day agree. Empty when not daily or when dayItems skips it ("None today.").
function ider(key: string, daily: boolean): (text: string) => string {
  return text => {
    const it = daily ? CloudSync.dayItems(`## ${key}\n- ${text}`).items[0] : undefined;
    return it ? ` data-id="${it.id}"` : "";
  };
}

/// Daily pages list plain sections from the tree so each top-level bullet can carry an id;
/// anything with headings, code or tasks keeps NotePage's generic layout.
function plainOrGeneric(s: Section, markdown: string, daily: boolean): string {
  if (!daily || !s.blocks.every(b => b.t === "bullet" || b.t === "para")) return generic(s.blocks);
  const id = ider(s.key, true);
  return `<ul class="plain">${tree(markdown, s.key).map(i => `<li${id(i.text)}>${inl(i.text)}${kids(i.kids)}</li>`).join("")}</ul>\n` + paras(s);
}

function section(s: Section, n: number, inner: string): string {
  return `<section id="${anchor(s.title)}" class="sec">\n<h2>${esc(s.title)}${n > 0 ? ` <span class="n">${n}</span>` : ""}</h2>\n${inner}</section>\n`;
}

/// "2026-11-12 — Day in review" -> the date large, the takeaway beneath it.
/// A week's title carries the Sunday it was written; the week shown is
/// the seven days before it.
function hero(title: string, summary: Section | undefined, morning: boolean, daily: boolean): string {
  const [day, kind] = title.split(" — ");
  const d = parseLocalDate(day ?? "", false);
  const short = (x: Date) => `${x.getDate()} ${fmt.month(x, "short")}`;
  const date = !d ? title || (morning ? "This week" : "Today")
    : morning ? `${short(new Date(d.getFullYear(), d.getMonth(), d.getDate() - 7))} – ${short(new Date(d.getFullYear(), d.getMonth(), d.getDate() - 1))}`
    : `${fmt.weekday(d)}, ${d.getDate()} ${fmt.month(d)}`;
  const fallback = morning ? "Week in review" : "Day in review";
  const { headline, paras } = lead(summary);
  return `<header class="sky">
<div class="${morning ? "sun" : "moon"}" aria-hidden="true"></div>
<p class="eyebrow"><span>${esc(d ? kind || fallback : fallback)}</span>${d ? `<span class="yr">${d.getFullYear()}</span>` : ""}</p>
<p class="date">${esc(date)}</p>
${headline ? `<h1${daily ? ' data-id="headline"' : ""}>${inl(headline)}</h1>` : ""}
</header>
${paras.length ? `<div class="summary">${paras.map(p => `<p>${inl(p)}</p>`).join("")}</div>` : ""}`;
}

/// The digest numbers. Zero tiles are left out rather than shown as "0".
function tiles(s: DayStats): string {
  const items: [string, string][] = [];
  const mins = (secs: number) => Math.round(secs / 60);
  if (mins(s.codingSeconds) >= 1) items.push([duration(mins(s.codingSeconds)), "coding"]);
  if (mins(s.activeSeconds) >= 1) items.push([duration(mins(s.activeSeconds)), "at the computer"]);
  if (s.meetings > 0) items.push([String(s.meetings), s.meetings === 1 ? "meeting" : "meetings"]);
  if (s.messages > 0) items.push([String(s.messages), s.messages === 1 ? "message" : "messages"]);
  if (!items.length) return "";
  return `<div class="tiles">${items.map(([v, k]) => `<div class="tile"><b>${esc(v)}</b><span>${esc(k)}</span></div>`).join("")}</div>\n`;
}

/// DayLogger.humanDuration, repeated here so this file doesn't import DayLogger back.
function duration(minutes: number): string {
  const h = Math.floor(minutes / 60), m = minutes % 60;
  return h === 0 ? `${m}m` : m === 0 ? `${h}h` : `${h}h ${m}m`;
}

const paras = (s: Section) => s.blocks.filter(b => b.t === "para" && !isNone(b.s)).map(b => `<p>${inl(b.s)}</p>`).join("");

function kids(items: Item[]): string {
  return items.length ? `<ul class="kids">${items.map(k => `<li>${withStatus(k.text)}${kids(k.kids)}</li>`).join("")}</ul>` : "";
}

function timeline(items: Item[], id: (t: string) => string): string {
  return `<ol class="line">${items.map(i => `<li${id(i.text)}>${withStatus(i.text)}${kids(i.kids)}</li>`).join("")}</ol>\n`;
}

function meetings(items: Item[], id: (t: string) => string): string {
  return `<div class="meets">${items.map(i => {
    const m = LEAD_TIME.exec(i.text);
    // "**10:31, Standup**:" -> the time leaves the bold, the title keeps it.
    const rest = m ? (m[1] && !m[3] ? "**" : "") + i.text.slice(m[0].length) : i.text;
    const time = m ? m[2].trim() : "";
    return `<div class="meet"${id(i.text)}>${time ? `<span class="tm">${esc(time)}</span>` : ""}<div class="mb"><p>${inl(rest)}</p>${kids(i.kids)}</div></div>`;
  }).join("")}</div>\n`;
}

function statusList(items: Item[], id: (t: string) => string): string {
  return `<ul class="chat">${items.map(i => `<li${id(i.text)}>${withStatus(i.text)}${kids(i.kids)}</li>`).join("")}</ul>\n`;
}

/// Open tasks as checkboxes. Disabled as written, so a sent copy is
/// read-only; the Share widget enables them and saves a tick (/task).
/// `data-i` counts only bullets with a status, as markTask does.
function todoList(items: Item[], id: (t: string) => string): string {
  let n = -1;
  return `<ul class="chat">${items.map(i => {
    const m = STATUS.exec(i.text);
    if (!m) return `<li${id(i.text)}>${inl(i.text)}${kids(i.kids)}</li>`;
    n++;
    const st = m[1].toLowerCase();
    return `<li class="todo"${id(i.text)}><label><input type="checkbox" class="nx-todo" data-i="${n}"${st === "done" ? " checked" : ""} disabled>`
      + `<span>${inl(i.text.slice(0, m.index))}</span>${st === "unclear" ? ` <span class="st unclear">unclear</span>` : ""}</label>${kids(i.kids)}</li>`;
  }).join("")}</ul>\n`;
}

/// Ticks (or unticks) the `index`th task under "## Open tasks": its tail
/// becomes "— done" (or "— open"). Null when there's no such task.
function markTask(markdown: string, index: number, done: boolean): string | null {
  const lines = markdown.split("\n");
  let inside = false, n = 0;
  for (let k = 0; k < lines.length; k++) {
    const raw = lines[k];
    if (raw.startsWith("## ")) { inside = raw.slice(3).trim().toLowerCase() === "open tasks"; continue; }
    if (!inside || !(raw.startsWith("- ") || raw.startsWith("* ")) || !STATUS.test(raw)) continue;
    if (n === index) { lines[k] = raw.replace(STATUS, done ? " — done" : " — open"); return lines.join("\n"); }
    n++;
  }
  return null;
}

/// A trailing "— open" becomes a pill; everything else stays as written.
function withStatus(t: string): string {
  const m = STATUS.exec(t);
  if (!m) return inl(t);
  const st = m[1].toLowerCase();
  return `${inl(t.slice(0, m.index))} <span class="st ${st}">${st}</span>`;
}

// Sunrise over the dusk sheet: peach-to-sky header with a sun, warm paper
// and terracotta ink by day; a dawn plum by night. Only the tokens and the
// header change, so both pages keep one layout.
const morningCSS = `
:root {
  --bg: #fbf6ee; --surface: #fffdf9; --ink: #2d2118; --muted: #6e5b4b; --faint: #a8968a; --line: #efe3d3;
  --accent: #c2531f; --lamp: #d9891a; --lamp-soft: #fdecd0; --indigo-soft: #fbe6d6; --sage: #e2f0e2; --rose: #fbe3e2;
  --sky-a: #ffcf9a; --sky-b: #9fd2f0; --sky-ink: #2d2118; --sky-muted: #7a5a3f;
}
@media (prefers-color-scheme: dark) { :root:not([data-theme="light"]) {
  --bg: #17110d; --surface: #211913; --ink: #f5ebe1; --muted: #c4b2a2; --faint: #8a7768; --line: #3a2c22;
  --accent: #ff9a5c; --lamp: #f5b54a; --lamp-soft: #3d2c17; --indigo-soft: #33241a; --sage: #1c3326; --rose: #3d2228;
  --sky-a: #5b2e3c; --sky-b: #d0773f; --sky-ink: #fff4e8; --sky-muted: #f2c9a4; color-scheme: dark; } }
:root[data-theme="dark"] {
  --bg: #17110d; --surface: #211913; --ink: #f5ebe1; --muted: #c4b2a2; --faint: #8a7768; --line: #3a2c22;
  --accent: #ff9a5c; --lamp: #f5b54a; --lamp-soft: #3d2c17; --indigo-soft: #33241a; --sage: #1c3326; --rose: #3d2228;
  --sky-a: #5b2e3c; --sky-b: #d0773f; --sky-ink: #fff4e8; --sky-muted: #f2c9a4; color-scheme: dark; }
.sky { background: linear-gradient(200deg, var(--sky-b) 0%, var(--sky-a) 100%); }
.sun { position: absolute; top: 22px; right: 26px; width: 56px; height: 56px; border-radius: 50%;
  background: radial-gradient(circle, #fff6d8 0 38%, #ffd36b 60%, #ffb347 100%);
  box-shadow: 0 0 0 10px rgba(255, 214, 120, .28), 0 0 44px 18px rgba(255, 190, 90, .45); }
.date { font-weight: 900; letter-spacing: -.025em; }
h1 { font-weight: 600; }
h2 { font-weight: 800; letter-spacing: -.01em; }
@media print { .sun { display: none; } }
`;

// Dusk palette: warm paper and indigo ink by day, deep indigo with lamp-amber
// by night. Fraunces for the date and headline sets it apart from the
// meeting page's all-sans look.
const css = `
:root {
  --bg: #f7f4ee; --surface: #fffdf8; --ink: #1f2140; --muted: #5d5f7a; --faint: #9496ad; --line: #e6e1ef;
  --accent: #4b46b8; --lamp: #c9821c; --lamp-soft: #fdeccb; --indigo-soft: #e7e6fb; --sage: #e1f0e4; --rose: #fbe3e6;
  --sky-a: #2b2a6b; --sky-b: #5a4a9c; --sky-ink: #f4f1ff; --sky-muted: #c9c3ee;
  --serif: "Fraunces", Georgia, "Cambria", serif;
  --sans: "DM Sans", "Segoe UI", -apple-system, "Helvetica Neue", sans-serif;
  --mono: "DM Mono", "Cascadia Mono", Consolas, ui-monospace, Menlo, monospace;
}
@media (prefers-color-scheme: dark) { :root:not([data-theme="light"]) {
  --bg: #0f1024; --surface: #171936; --ink: #e9e8f6; --muted: #a4a6c4; --faint: #6f7194; --line: #262955;
  --accent: #a9a5ff; --lamp: #f2b85a; --lamp-soft: #3a2f1a; --indigo-soft: #23255a; --sage: #1c3326; --rose: #3d2230;
  --sky-a: #1a1a46; --sky-b: #3a2f6e; color-scheme: dark; } }
:root[data-theme="dark"] {
  --bg: #0f1024; --surface: #171936; --ink: #e9e8f6; --muted: #a4a6c4; --faint: #6f7194; --line: #262955;
  --accent: #a9a5ff; --lamp: #f2b85a; --lamp-soft: #3a2f1a; --indigo-soft: #23255a; --sage: #1c3326; --rose: #3d2230;
  --sky-a: #1a1a46; --sky-b: #3a2f6e; color-scheme: dark; }
* { box-sizing: border-box; }
body { margin: 0; background: var(--bg); color: var(--ink); font: 400 16px/1.6 var(--sans); -webkit-font-smoothing: antialiased; }
main { max-width: 760px; margin: 0 auto; padding-block: 40px 72px; padding-left: max(16px, env(safe-area-inset-left, 0px)); padding-right: max(16px, env(safe-area-inset-right, 0px)); }
p { margin: 0; }
b, strong { font-weight: 650; }
code { font-family: var(--mono); font-size: .86em; background: var(--indigo-soft); padding: 1px 5px; border-radius: 5px; }

.sky { position: relative; overflow: hidden; display: grid; gap: 10px; padding: 34px 32px 32px; border-radius: 24px; color: var(--sky-ink);
  background: radial-gradient(circle at 20% 30%, rgba(255,255,255,.5) 0 1px, transparent 1.5px) 0 0 / 90px 70px,
              radial-gradient(circle at 70% 60%, rgba(255,255,255,.35) 0 1px, transparent 1.5px) 0 0 / 130px 110px,
              linear-gradient(160deg, var(--sky-a), var(--sky-b)); }
.moon { position: absolute; top: 26px; right: 30px; width: 46px; height: 46px; border-radius: 50%; box-shadow: -12px 4px 0 0 #f6d58c; transform: rotate(-20deg); }
.eyebrow { display: flex; gap: 12px; font: 500 12px/1.4 var(--mono); letter-spacing: .08em; text-transform: uppercase; color: var(--sky-muted); }
.date { font: 600 clamp(30px, 6vw, 46px)/1.05 var(--serif); letter-spacing: -.01em; }
h1 { margin: 8px 0 0; max-width: 34ch; font: 500 clamp(18px, 2.6vw, 21px)/1.45 var(--serif); color: var(--sky-ink); text-wrap: pretty; }
.summary { display: grid; gap: 10px; padding: 22px 4px 0; color: var(--muted); font-size: 16.5px; max-width: 64ch; }

.tiles { display: grid; grid-template-columns: repeat(auto-fit, minmax(140px, 1fr)); gap: 10px; margin-top: 22px; }
.tile { display: grid; gap: 2px; background: var(--surface); border: 1px solid var(--line); border-radius: 16px; padding: 14px 16px; }
.tile b { font: 500 24px/1.2 var(--mono); color: var(--accent); font-variant-numeric: tabular-nums; }
.tile span { color: var(--muted); font-size: 13.5px; }

.sec { padding-top: 40px; display: grid; gap: 14px; }
h2 { margin: 0; display: flex; align-items: baseline; gap: 10px; font: 600 22px/1.2 var(--serif); }
h2 .n { font: 500 12px/1 var(--mono); color: var(--lamp); background: var(--lamp-soft); border-radius: 99px; padding: 4px 8px; }
h3 { margin: 8px 0 0; font-size: 16px; }
ul, ol { margin: 0; padding: 0; list-style: none; }

.line { position: relative; display: grid; gap: 16px; padding-left: 26px; }
.line::before { content: ""; position: absolute; left: 6px; top: 8px; bottom: 8px; width: 2px; border-radius: 2px; background: linear-gradient(var(--lamp), var(--accent)); }
.line > li { position: relative; }
.line > li::before { content: ""; position: absolute; left: -26px; top: .42em; width: 14px; height: 14px; border-radius: 50%; background: var(--bg); border: 3px solid var(--lamp); }

.meets { display: grid; gap: 10px; }
.meet { display: flex; gap: 14px; align-items: flex-start; background: var(--surface); border: 1px solid var(--line); border-left: 4px solid var(--accent); border-radius: 14px; padding: 14px 16px; }
.tm { flex: none; font: 500 13px/1 var(--mono); color: var(--accent); background: var(--indigo-soft); border-radius: 8px; padding: 6px 8px; margin-top: 1px; }
.mb { min-width: 0; display: grid; gap: 6px; }
.kids { display: grid; gap: 5px; margin-top: 6px; padding-left: 18px; list-style: disc; color: var(--muted); font-size: 15px; }
.kids .kids { margin-top: 4px; font-size: 14px; list-style: circle; }
.kids li::marker { color: var(--faint); }

.chat { display: grid; gap: 8px; }
.chat > li { background: var(--surface); border: 1px solid var(--line); border-radius: 12px; padding: 12px 14px; }
.st { display: inline-block; font: 500 11.5px/1 var(--mono); text-transform: uppercase; letter-spacing: .05em; border-radius: 99px; padding: 4px 8px; margin-left: 4px; vertical-align: 2px; }
.st.done { background: var(--sage); }
.st.open { background: var(--lamp-soft); color: var(--lamp); }
.st.unclear { background: var(--rose); }
.todo label { display: flex; gap: 10px; align-items: baseline; cursor: pointer; }
.todo input { flex: none; width: 17px; height: 17px; margin: 0; transform: translateY(3px); accent-color: var(--accent); cursor: pointer; }
.todo input:checked + span { text-decoration: line-through; color: var(--faint); }

.pair { display: grid; grid-template-columns: repeat(auto-fit, minmax(min(100%, 300px), 1fr)); gap: 12px; padding-top: 40px; }
.panel { padding: 18px 20px; background: var(--indigo-soft); border-radius: 18px; gap: 10px; }
.panel h2 { font-size: 18px; }
.plain { display: grid; gap: 8px; padding-left: 20px; list-style: disc; }
.panel .plain { font-size: 15px; }
pre { margin: 0; padding: 14px 16px; overflow-x: auto; background: var(--surface); border: 1px solid var(--line); border-radius: 12px; font: 400 13px/1.6 var(--mono); white-space: pre-wrap; }
pre code { background: none; padding: 0; }

.x { text-decoration: line-through; opacity: .45 }
.nx-send { margin-top: 40px; display: flex; flex-wrap: wrap; align-items: center; gap: 10px 14px; padding: 16px 18px; background: var(--surface); border: 1px solid var(--line); border-radius: 16px; }
.nx-send[hidden] { display: none; }
.nx-send p { flex: 1 1 240px; color: var(--muted); font-size: 14.5px; }
.nx-send button { font: 600 14px/1 var(--sans); color: var(--bg); background: var(--accent); border: 0; border-radius: 999px; padding: 10px 16px; cursor: pointer; }
.nx-send button:disabled { opacity: .6; cursor: default; }
.nx-send .nx-prev { color: var(--accent); background: var(--indigo-soft); }
.nx-pv { width: min(680px, calc(100vw - 32px)); max-height: calc(100vh - 48px); padding: 0; border: 1px solid var(--line); border-radius: 20px; background: var(--bg); color: var(--ink); }
.nx-pv::backdrop { background: rgba(12, 12, 32, .5); }
.pv-head { position: sticky; top: 0; z-index: 1; display: grid; gap: 10px; padding: 18px 20px 14px; background: var(--bg); border-bottom: 1px solid var(--line); }
.pv-head b { font: 600 18px/1.3 var(--serif); }
.pv-head small { color: var(--muted); font-size: 13.5px; }
.pv-tabs { display: flex; flex-wrap: wrap; gap: 6px; }
.pv-tabs button, .pv-foot button { font: 600 13.5px/1 var(--sans); padding: 9px 14px; border-radius: 999px; border: 1px solid var(--line); background: var(--surface); color: var(--muted); cursor: pointer; }
.pv-tabs button[aria-pressed="true"] { background: var(--ink); border-color: var(--ink); color: var(--bg); }
.pv-body { padding: 16px 20px; }
.pv-card { display: grid; gap: 10px; padding: 18px; background: var(--surface); border: 1px solid var(--line); border-radius: 16px; }
.pv-date { font: 500 12px/1.2 var(--mono); letter-spacing: .07em; text-transform: uppercase; color: var(--muted); }
.pv-hl { font: 500 18px/1.45 var(--serif); }
.pv-hl { flex-wrap: nowrap; } .pv-hl span { flex: 1; min-width: 0; }
.pv-bar { display: flex; gap: 2px; height: 10px; border-radius: 99px; overflow: hidden; }
.pv-bar i { background: var(--pv); }
.pv-legend { color: var(--muted); font-size: 13px; }
.nx-pv h3 { margin: 12px 0 2px; font: 600 15px/1.3 var(--serif); }
.pv-items > li { padding: 9px 0; border-top: 1px solid var(--line); }
.pv-row { display: flex; flex-wrap: wrap; align-items: baseline; gap: 4px 10px; cursor: pointer; }
.pv-tick { flex: none; width: 17px; height: 17px; margin: 0; transform: translateY(3px); accent-color: var(--accent); cursor: pointer; }
.pv-what { flex: 1 1 240px; min-width: 0; overflow-wrap: anywhere; }
.pv-min { font: 500 13px/1 var(--mono); color: var(--muted); }
.pv-proj { flex: none; font: 500 12px/1 var(--sans); color: var(--muted); background: var(--line); border-radius: 99px; padding: 4px 9px; }
.pv-chip { flex: none; font: 600 10.5px/1 var(--mono); letter-spacing: .05em; text-transform: uppercase; color: #fff; background: var(--pv); border-radius: 6px; padding: 4px 7px; }
.pv-items details { margin: 4px 0 0 27px; color: var(--muted); font-size: 14px; }
.pv-items summary { cursor: pointer; }
.pv-items details ul { display: grid; gap: 4px; margin-top: 4px; padding-left: 18px; list-style: disc; }
.pv-gone .pv-what { text-decoration: line-through; color: var(--faint); }
.pv-empty { color: var(--muted); }
.pv-foot { position: sticky; bottom: 0; display: flex; justify-content: flex-end; gap: 8px; padding: 12px 20px; background: var(--bg); border-top: 1px solid var(--line); }
.pv-foot .pv-send { color: var(--bg); background: var(--accent); border-color: var(--accent); }
.pv-coding { --pv: #4b46b8; } .pv-shipped { --pv: #2f8a57; } .pv-meeting { --pv: #c9821c; } .pv-research { --pv: #2b7fa8; } .pv-learning { --pv: #8a4fb8; }
.pv-writing { --pv: #b8513f; } .pv-review { --pv: #5f7d2a; } .pv-planning { --pv: #a8457a; } .pv-comms { --pv: #2f9a96; } .pv-other { --pv: #7a7a92; }
.nx-sent { font: 500 13px/1.3 var(--mono); color: var(--muted); }
.nx-sent:empty { display: none; }

.empty { margin-top: 40px; padding-top: 18px; border-top: 1px dashed var(--line); color: var(--faint); font-size: 14px; }
footer { margin-top: 28px; color: var(--faint); font-size: 12.5px; }

@media (prefers-reduced-motion: no-preference) {
  .sky, .tiles, .sec, .pair { animation: rise .5s cubic-bezier(.2,.7,.2,1) both; }
  .tiles { animation-delay: .06s; }
  @keyframes rise { from { transform: translateY(8px); } to { transform: none; } }
}
@media print {
  body { background: #fff; } .sky { color: var(--ink); background: none; padding: 0; } .moon, footer, .nx-send { display: none; }
  .eyebrow { color: var(--muted); } h1 { color: var(--ink); } .sec { break-inside: avoid; }
}
`;

export const DayPage = { html, markTask };
