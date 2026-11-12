import { randomUUID } from "crypto";
import { escapeHtml as esc, fmt, inline as inl, isNone, parseLocalDate, splitFields } from "./markdown";

/// Port of NotePage.swift.
///
/// The "Page (.html)" note: the agent's Markdown laid out as a designed page
/// rather than a converted document. Known sections get their own component
/// (task cards you can tick, decision checks, risk callouts, question cards,
/// people cards, calendar tiles, copyable agent prompts); anything else -- a
/// custom template's own sections -- falls back to plain lists and paragraphs.
///
/// Opened in the default browser. PDF and Word keep markdownToHtml.

export type Block =
  | { t: "para" | "bullet" | "sub" | "code"; s: string }
  | { t: "task"; done: boolean; s: string };

export interface Section { title: string; key: string; blocks: Block[] }

/// Only "None." lines (or nothing at all).
export const isEmpty = (s: Section) => s.blocks.every(b => ["para", "bullet", "task"].includes(b.t) && isNone(b.s));
/// Items that count: bullets and tasks that aren't "None."
export const count = (s: Section) => s.blocks.filter(b => (b.t === "bullet" || b.t === "task") && !isNone(b.s)).length;
const bullets = (s: Section) => s.blocks.filter(b => b.t === "bullet" && !isNone(b.s)).map(b => b.s);

// MARK: - Parsing

export function parse(markdown: string): { title: string; sections: Section[] } {
  let title = "", code: string[] | null = null;
  const sections: Section[] = [];
  const section = (t: string): Section => ({ title: t, key: t.toLowerCase(), blocks: [] });
  const append = (b: Block) => {
    if (!sections.length) sections.push(section("Notes"));
    sections[sections.length - 1].blocks.push(b);
  };
  for (const raw of markdown.split(/\r\n|\r|\n/)) {
    const line = raw.trim();
    if (line.startsWith("```")) {
      if (code) { append({ t: "code", s: code.join("\n") }); code = null; } else code = [];
      continue;
    }
    if (code) { code.push(raw); continue; }
    if (!line || line === "---") continue;
    if (line.startsWith("# ")) { title = line.slice(2); continue; }
    if (line.startsWith("## ")) { sections.push(section(line.slice(3))); continue; }
    if (line.startsWith("###")) { append({ t: "sub", s: line.replace(/^#+/, "").trim() }); continue; }
    if (line.startsWith("- ") || line.startsWith("* ")) {
      const item = line.slice(2);
      if (item.startsWith("[ ] ")) append({ t: "task", done: false, s: item.slice(4) });
      else if (item.toLowerCase().startsWith("[x] ")) append({ t: "task", done: true, s: item.slice(4) });
      else append({ t: "bullet", s: item });
      continue;
    }
    append({ t: "para", s: line });
  }
  if (code) append({ t: "code", s: code.join("\n") });
  return { title, sections };
}

// MARK: - Page

function html(markdown: string): string {
  const { title, sections } = parse(markdown);
  const isMeeting = title.startsWith("Meeting");
  const find = (name: string) => sections.find(s => s.key === name);

  // Summary first, then what people act on, then context.
  const order = isMeeting
    ? ["action items", "decisions", "blockers & risks", "open questions", "follow-up meetings", "speakers", "agent prompts"]
    : ["key points", "notable quotes / examples", "open questions"];
  const ordered = order.map(find).filter((s): s is Section => !!s)
    .concat(sections.filter(s => !order.includes(s.key) && s.key !== "summary" && s.key !== "per-speaker highlights"));

  let body = "";
  const empty: string[] = [], nav: string[] = [];
  const highlights = find("per-speaker highlights");
  for (const s of ordered) {
    const people = s.key === "speakers";
    if (isEmpty(s) && !(people && highlights && !isEmpty(highlights))) { empty.push(s.title); continue; }
    const id = anchor(s.title);
    const label = people ? "People" : s.title;
    const n = people ? 0 : count(s);
    nav.push(`<a href="#${id}">${n > 0 ? `<b>${n}</b> ` : ""}${esc(label)}</a>`);
    body += `<section id="${id}" class="sec">\n<h2>${esc(label)}${n > 0 ? ` <span class="n">${n}</span>` : ""}</h2>\n`;
    switch (s.key) {
      case "action items": body += tasks(s); break;
      case "decisions": body += list(s, "decisions"); break;
      case "blockers & risks": body += marked(s, "risks", "risk", "!"); break;
      case "open questions": body += marked(s, "questions", "q", "?"); break;
      case "follow-up meetings": body += followUps(s, title); break;
      case "speakers": body += peopleCards(s, highlights); break;
      case "agent prompts": body += prompts(s); break;
      case "key points": body += list(s, "points"); break;
      case "notable quotes / examples": body += bullets(s).map(t => `<blockquote>${inl(t)}</blockquote>`).join("") + extras(s); break;
      default: body += generic(s.blocks);
    }
    body += "</section>\n";
  }
  if (empty.length) body += `<p class="empty">Nothing recorded for ${empty.map(esc).join(" · ")}.</p>\n`;

  // Google Fonts as on the Mac; the stacks fall back to Segoe UI / Consolas offline.
  return `<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<title>${esc(title || "Nikxel note")}</title>
<link rel="preconnect" href="https://fonts.googleapis.com"><link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Caveat:wght@600&family=DM+Mono:wght@400;500&family=DM+Sans:opsz,wght@9..40,400;9..40,500;9..40,600;9..40,700;9..40,800&display=swap">
<style>${css}</style></head><body>
<main>
${hero(title, find("summary"), isMeeting)}
${nav.length > 1 ? `<nav class="glance">${nav.join("")}</nav>` : ""}
${body}
<footer>Written by Nikxel from the recording's transcript. Tick tasks off here; the ticks stay in this browser only.</footer>
</main>
<script>${js}</script>
</body></html>
`;
}

// MARK: - Components

/// The summary's opening line as a headline, and the paragraphs after it.
/// Prompts v6+ write that line in bold; older notes have one long paragraph,
/// so their first sentence is promoted instead.
export function lead(summary: Section | undefined): { headline: string; paras: string[] } {
  const paras = (summary?.blocks ?? []).filter(b => b.t === "para").map(b => b.s);
  let headline = "";
  const first = paras[0];
  if (first !== undefined) {
    const stop = first.indexOf(". ");
    if (first.startsWith("**") && first.endsWith("**") && first.length > 4) { headline = first.slice(2, -2); paras.shift(); }
    else if (stop >= 0 && stop < 220) { headline = first.slice(0, stop) + "."; paras[0] = first.slice(stop + 2); }
    else if (first.length < 220) { headline = first; paras.shift(); }
  }
  return { headline, paras };
}

/// Eyebrow + date, then the summary's opening line as the headline.
function hero(title: string, summary: Section | undefined, isMeeting: boolean): string {
  const parts = title.split(" — ");
  let kind = isMeeting ? "Minutes of meeting" : parts[0] || "Notes";
  if (parts.length < 2) kind = title || "Note";
  let when = parts.length === 2 ? parts[1] : "";
  const d = parseLocalDate(when, true);
  if (d) when = `${fmt.weekday(d)} ${d.getDate()} ${fmt.month(d)} ${d.getFullYear()} · ${fmt.time(d)}`;

  const { headline, paras } = lead(summary);
  const rest = paras.map(p => `<p>${inl(p)}</p>`).join("");
  return `<header class="hero">
<p class="eyebrow"><span>${esc(kind)}</span>${when ? `<span class="when">${esc(when)}</span>` : ""}</p>
${headline ? `<p class="scribble" aria-hidden="true">in short</p><h1>${inl(headline)}</h1>` : ""}
${rest ? `<div class="summary">${rest}</div>` : ""}
</header>`;
}

function tasks(s: Section): string {
  let out = '<ul class="tasks">\n', i = 0;
  for (const b of s.blocks) {
    if (b.t !== "task" || isNone(b.s)) continue;
    i++;
    const { text, fields } = splitFields(b.s);
    const chips = fields.map(f => {
      const k = f.key.toLowerCase();
      if (k === "owner" && !isUnset(f.value)) return `<span class="chip who">${avatar(f.value, true)}${inl(f.value)}</span>`;
      if (k === "due" && !isUnset(f.value)) return `<span class="chip due">Due ${esc(shortDate(f.value))}</span>`;
      return `<span class="chip${isUnset(f.value) ? " unset" : ""}">${esc(f.key)} ${inl(f.value)}</span>`;
    }).join("");
    out += `<li class="task"><input type="checkbox" id="task-${i}"${b.done ? " checked" : ""}>
<label for="task-${i}"><span class="t">${inl(stripBold(text))}</span>${chips ? `<span class="chips">${chips}</span>` : ""}</label></li>\n`;
  }
  return out + "</ul>\n";
}

function list(s: Section, cls: string): string {
  return `<ul class="${cls}">` + bullets(s).map(t => `<li>${inl(t)}</li>`).join("") + "</ul>\n" + extras(s);
}

/// Risk callouts ("!") and question cards ("?").
function marked(s: Section, cls: string, item: string, mark: string): string {
  return `<div class="${cls}">` + bullets(s).map(t =>
    `<div class="${item}"><span class="mark" aria-hidden="true">${mark}</span><p>${inl(t)}</p></div>`).join("") + "</div>\n" + extras(s);
}

/// Calendar tiles, each with one-click "add to calendar": a pre-filled
/// Google Calendar event (they just press Save) and an .ics, which Outlook /
/// Windows Calendar open (the Mac labels it Apple / Outlook). No login, no
/// server -- works from the local file. Times are local ("floating"), which
/// is what the meeting said.
function followUps(s: Section, noteTitle: string): string {
  return '<div class="meets">' + bullets(s).map(item => {
    const { text, fields } = splitFields(item);
    const f: Record<string, string> = {};
    for (const x of fields) f[x.key.toLowerCase()] = x.value;
    const when = f["when"] ?? "";
    let month = "TBD", day = "–", time = "";
    const withTime = parseLocalDate(when, true);
    const start = withTime ?? parseLocalDate(when, false);
    const hasTime = !!withTime;
    if (start) {
      month = fmt.month(start, "short");
      day = String(start.getDate());
      time = hasTime
        ? `${fmt.weekday(start, "short")} · ${pad(start.getHours())}:${pad(start.getMinutes())}`
        : `${fmt.weekday(start)} · time not set`;
    }
    const withWho = f["with"] && !isUnset(f["with"]) ? f["with"] : null;
    const meta = [time, f["duration"] ?? "", withWho ? `with ${withWho}` : ""].filter(Boolean).map(esc).join(" · ");

    const title = plain(stripBold(text));
    const minutes = parseInt(/^\d*/.exec(f["duration"] ?? "")![0], 10) || 30;
    const details = [`Agreed in: ${noteTitle}`, ...(withWho ? [`With: ${withWho}`] : [])].join("\n");
    const links = calendarLinks(title, start, hasTime, minutes, details);
    return `<div class="meet"><div class="cal"><span>${esc(month)}</span><b>${esc(day)}</b></div>
<div class="mb"><p class="mt">${inl(stripBold(text))}</p><p class="mm">${meta}</p>
<div class="add"><a class="btn primary" href="${esc(links.google)}" target="_blank" rel="noopener">Add to Google Calendar</a><a class="btn" href="${esc(links.ics)}" download="${esc(fileName(title))}.ics">Outlook / other (.ics)</a></div></div></div>`;
  }).join("") + "</div>\n";
}

/// Google's event template URL and an .ics data URI for the same event.
/// No date -> Google opens with today (they pick); no time -> all day.
function calendarLinks(title: string, start: Date | null, hasTime: boolean, minutes: number, details: string): { google: string; ics: string } {
  const stamp = (d: Date) => `${d.getFullYear()}${pad(d.getMonth() + 1)}${pad(d.getDate())}`;
  const stampTime = (d: Date) => `${stamp(d)}T${pad(d.getHours())}${pad(d.getMinutes())}${pad(d.getSeconds())}`;
  let dates = "", dtStart = "", dtEnd = "";
  if (start) {
    if (hasTime) {
      const end = new Date(start.getTime() + Math.max(minutes, 5) * 60_000);
      dates = `${stampTime(start)}/${stampTime(end)}`;
      dtStart = `DTSTART:${stampTime(start)}`; dtEnd = `DTEND:${stampTime(end)}`;
    } else {
      const end = new Date(start.getFullYear(), start.getMonth(), start.getDate() + 1);
      dates = `${stamp(start)}/${stamp(end)}`;
      dtStart = `DTSTART;VALUE=DATE:${stamp(start)}`; dtEnd = `DTEND;VALUE=DATE:${stamp(end)}`;
    }
  }
  const q = new URLSearchParams({ action: "TEMPLATE", text: title, details, ...(dates ? { dates } : {}) });
  const google = `https://calendar.google.com/calendar/render?${q}`;

  const icsText = (s: string) => s.replace(/\\/g, "\\\\").replace(/;/g, "\\;").replace(/,/g, "\\,").replace(/\n/g, "\\n");
  const utc = new Date().toISOString().replace(/[-:]/g, "").replace(/\.\d+Z$/, "Z");
  const ics = ["BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//Nikxel//Notes//EN", "BEGIN:VEVENT",
    `UID:${randomUUID().toUpperCase()}@nikxel`, `DTSTAMP:${utc}`,
    dtStart, dtEnd, `SUMMARY:${icsText(title)}`, `DESCRIPTION:${icsText(details)}`,
    "END:VEVENT", "END:VCALENDAR"].filter(Boolean).join("\r\n");
  return { google, ics: `data:text/calendar;charset=utf-8,${encodeURIComponent(ics)}` };
}

const pad = (n: number) => String(n).padStart(2, "0");
const plain = (s: string) => s.replace(/\*\*/g, "").replace(/`/g, "");

function fileName(s: string): string {
  const cleaned = s.replace(/[^\p{L}\p{N}]+/gu, " ").trim().split(" ").filter(Boolean).join("-");
  return cleaned ? Array.from(cleaned).slice(0, 60).join("") : "meeting";
}

/// Speakers (who and why we think so) merged with Per-Speaker Highlights
/// (what they said) into one card per person.
function peopleCards(speakers: Section, highlights: Section | undefined): string {
  const people: { name: string; role: string; body: string }[] =
    bullets(speakers).map(t => { const [name, role] = splitPerson(t); return { name, role, body: "" }; });
  // Highlights: "**Name**" then bullets, or "**Name:** paragraph".
  let current: number | null = null;
  let pending: string[] = [];
  const flush = () => {
    if (current !== null && pending.length) people[current].body += "<ul>" + pending.map(b => `<li>${inl(b)}</li>`).join("") + "</ul>";
    pending = [];
  };
  for (const b of highlights?.blocks ?? []) {
    if (b.t === "para" && b.s.startsWith("**")) {
      flush();
      const [name, rest] = splitPerson(b.s);
      const key = norm(name);
      const i = people.findIndex(p => norm(p.name) === key || norm(p.name).startsWith(key) || key.startsWith(norm(p.name)));
      if (i >= 0) current = i;
      else { people.push({ name, role: "", body: "" }); current = people.length - 1; }
      if (rest) people[current].body += `<p>${inl(rest)}</p>`;
    } else if (b.t === "bullet") pending.push(b.s);
    else if (b.t === "para" && current !== null) people[current].body += `<p>${inl(b.s)}</p>`;
  }
  flush();
  return '<div class="people">' + people.map(p =>
    `<article class="person"><div class="ph">${avatar(p.name, false)}<div><p class="pn">${inl(p.name)}</p>${p.role ? `<p class="pr">${inl(p.role)}</p>` : ""}</div></div>
${p.body ? `<div class="pb">${p.body}</div>` : ""}</article>`).join("") + "</div>\n";
}

function prompts(s: Section): string {
  let out = "", title = "";
  for (const b of s.blocks) {
    if (b.t === "sub") title = b.s;
    else if (b.t === "code") {
      out += `<div class="prompt"><div class="prh"><p>${inl(title || "Prompt")}</p><button type="button" class="copy">Copy</button></div>
<pre><code>${esc(b.s)}</code></pre></div>\n`;
      title = "";
    }
  }
  return out || generic(s.blocks);
}

/// Paragraphs and stray lines a component didn't consume.
function extras(s: Section): string {
  return s.blocks.filter(b => b.t === "para" && !isNone(b.s)).map(b => `<p>${inl(b.s)}</p>`).join("");
}

export function generic(blocks: Block[]): string {
  let out = "", open = false;
  for (const b of blocks) {
    if (b.t !== "bullet" && open) { out += "</ul>"; open = false; }
    switch (b.t) {
      case "bullet": if (!open) { out += '<ul class="plain">'; open = true; } out += `<li>${inl(b.s)}</li>`; break;
      case "para": out += `<p>${inl(b.s)}</p>`; break;
      case "task": out += `<p>☐ ${inl(b.s)}</p>`; break;
      case "sub": out += `<h3>${inl(b.s)}</h3>`; break;
      case "code": out += `<pre><code>${esc(b.s)}</code></pre>`; break;
    }
  }
  return out + (open ? "</ul>" : "") + "\n";
}

// MARK: - Helpers

const isUnset = (v: string) => ["not specified", "unassigned"].includes(v.toLowerCase());

const stripBold = (s: string) => s.startsWith("**") && s.endsWith("**") && s.length > 4 ? s.slice(2, -2) : s;

/// "**Name (Me)** — role", "Name (Me): role", "**Name:** text" -> [name, rest]
function splitPerson(t: string): [string, string] {
  const end = t.startsWith("**") ? t.indexOf("**", 2) : -1;
  if (end >= 0) {
    let name = t.slice(2, end).trim();
    if (name.endsWith(":")) name = name.slice(0, -1);
    let rest = t.slice(end + 2).trim();
    for (const p of ["—", ":", "-"]) if (rest.startsWith(p)) rest = rest.slice(p.length).trim();
    return [name, rest];
  }
  for (const sep of [" — ", ": "]) {
    const i = t.indexOf(sep);
    if (i >= 0) return [t.slice(0, i), t.slice(i + sep.length)];
  }
  return [t, ""];
}

const norm = (s: string) => s.toLowerCase().replace(/\*/g, "").split(" (")[0].trim();

/// Initials on one of five pastel grounds, picked by the name so a person
/// keeps their colour across the page.
function avatar(name: string, small: boolean): string {
  const clean = norm(name);
  const initials = clean.split(" ").filter(w => /^\p{L}/u.test(w)).slice(0, 2).map(w => Array.from(w)[0]).join("").toUpperCase();
  let tone = 0;
  for (const ch of clean) tone += ch.codePointAt(0)!;
  return `<span class="av t${tone % 5}${small ? " sm" : ""}" aria-hidden="true">${esc(initials || "?")}</span>`;
}

function shortDate(v: string): string {
  const d = parseLocalDate(v, false);
  return d ? `${fmt.weekday(d, "short")} ${d.getDate()} ${fmt.month(d, "short")}` : v;
}

export const anchor = (s: string) => s.toLowerCase().replace(/[^\p{L}\p{N}]+/gu, "-").replace(/^-+|-+$/g, "");

export const NotePage = { html, calendarLinks };

// MARK: - Style

// Layout: one reading column; the hero states the takeaway, components
// below are shaped by what each section is for. Brand palette from the
// website (paper green, ink, green accent, pastel grounds). Font fallbacks
// are Windows' (Segoe UI / Segoe Print / Cascadia Mono, Consolas).
const css = `
:root {
  --bg: #f6faf5; --surface: #ffffff; --ink: #25302a; --muted: #5c6a60; --faint: #8a968d; --line: #d7e9d6;
  --accent: #23864d; --mint: #d6f3e3; --butter: #fff3c4; --lilac: #e8ddff; --peach: #ffe6d3; --sky: #e1eeff;
  --warn-ink: #8a4a1c; --code-bg: #1f2823; --code-ink: #dfeee3;
  --sans: "DM Sans", "Segoe UI", -apple-system, Helvetica, sans-serif;
  --hand: "Caveat", "Segoe Print", "Bradley Hand", cursive;
  --mono: "DM Mono", "Cascadia Mono", Consolas, ui-monospace, monospace;
}
@media (prefers-color-scheme: dark) { :root:not([data-theme="light"]) {
  --bg: #111613; --surface: #181f1b; --ink: #e4efe7; --muted: #9eaca2; --faint: #74827a; --line: #26322b;
  --accent: #6fd396; --mint: #1d3a2a; --butter: #3a3320; --lilac: #2c2640; --peach: #3c2a1f; --sky: #1c2a3c;
  --warn-ink: #ffc8a6; --code-bg: #0c100e; --code-ink: #dfeee3; color-scheme: dark; } }
:root[data-theme="dark"] {
  --bg: #111613; --surface: #181f1b; --ink: #e4efe7; --muted: #9eaca2; --faint: #74827a; --line: #26322b;
  --accent: #6fd396; --mint: #1d3a2a; --butter: #3a3320; --lilac: #2c2640; --peach: #3c2a1f; --sky: #1c2a3c;
  --warn-ink: #ffc8a6; --code-bg: #0c100e; --code-ink: #dfeee3; color-scheme: dark; }
* { box-sizing: border-box; }
body { margin: 0; background: var(--bg); color: var(--ink); font: 400 16px/1.6 var(--sans); -webkit-font-smoothing: antialiased; }
main { max-width: 780px; margin: 0 auto; padding-block: 56px 72px; padding-left: max(20px, env(safe-area-inset-left, 0px)); padding-right: max(20px, env(safe-area-inset-right, 0px)); }
p { margin: 0; }
b, strong { font-weight: 650; }
code { font-family: var(--mono); font-size: .86em; background: var(--mint); padding: 1px 5px; border-radius: 5px; }

.hero { display: grid; gap: 14px; padding-bottom: 28px; }
.eyebrow { display: flex; flex-wrap: wrap; gap: 6px 14px; font: 500 12px/1.4 var(--mono); letter-spacing: .06em; text-transform: uppercase; color: var(--accent); }
.eyebrow .when { color: var(--muted); }
.scribble { font: 600 26px/1 var(--hand); color: var(--accent); transform: rotate(-3deg); transform-origin: left; margin: 18px 0 -6px; }
h1 { margin: 0; font: 750 clamp(27px, 4.4vw, 38px)/1.16 var(--sans); letter-spacing: -.02em; text-wrap: balance; }
.summary { display: grid; gap: 10px; max-width: 64ch; color: var(--muted); font-size: 16.5px; }

.glance { display: flex; flex-wrap: wrap; gap: 8px; padding: 18px 0; border-block: 1px solid var(--line); }
.glance a { font: 400 13px/1 var(--mono); color: var(--muted); text-decoration: none; background: var(--surface); border: 1px solid var(--line); border-radius: 99px; padding: 8px 12px; }
.glance a:hover, .glance a:focus-visible { border-color: var(--accent); color: var(--ink); outline: none; }
.glance b { font-weight: 500; color: var(--accent); font-variant-numeric: tabular-nums; }
.sec { padding-top: 44px; display: grid; gap: 16px; }
h2 { margin: 0; display: flex; align-items: baseline; gap: 10px; font: 700 13px/1.2 var(--sans); letter-spacing: .09em; text-transform: uppercase; color: var(--ink); }
h2 .n { font: 500 12px/1 var(--mono); color: var(--accent); background: var(--mint); border-radius: 99px; padding: 4px 8px; letter-spacing: 0; }
h3 { margin: 8px 0 0; font-size: 16px; }

ul { margin: 0; padding: 0; list-style: none; }
.tasks { display: grid; gap: 10px; }
.task { display: flex; gap: 14px; align-items: flex-start; background: var(--surface); border: 1px solid var(--line); border-radius: 14px; padding: 16px 18px; transition: opacity .2s, transform .2s; }
.task:hover { transform: translateY(-1px); }
.task input { appearance: none; flex: none; width: 22px; height: 22px; margin: 1px 0 0; border: 2px solid var(--accent); border-radius: 7px; cursor: pointer; display: grid; place-content: center; background: var(--surface); }
.task input::after { content: ""; width: 10px; height: 6px; border: solid var(--surface); border-width: 0 0 2.5px 2.5px; transform: rotate(-45deg) translate(1px, -1px); opacity: 0; }
.task input:checked { background: var(--accent); }
.task input:checked::after { opacity: 1; }
.task input:focus-visible { outline: 3px solid var(--mint); outline-offset: 2px; }
.task label { display: grid; gap: 10px; min-width: 0; cursor: pointer; }
.task .t { font-weight: 600; line-height: 1.45; }
.task:has(input:checked) { opacity: .55; }
.task:has(input:checked) .t { text-decoration: line-through; text-decoration-color: var(--faint); }
.chips { display: flex; flex-wrap: wrap; gap: 6px; }
.chip { display: inline-flex; align-items: center; gap: 6px; font: 500 12.5px/1 var(--sans); background: var(--mint); border-radius: 99px; padding: 4px 10px 4px 10px; }
.chip.who { padding-left: 3px; }
.chip.due { background: var(--butter); font-family: var(--mono); font-size: 12px; }
.chip.unset { background: transparent; border: 1px dashed var(--line); color: var(--faint); }

.decisions { display: grid; gap: 10px; }
.decisions li { position: relative; padding-left: 34px; font-weight: 500; }
.decisions li::before { content: "✓"; position: absolute; left: 0; top: 1px; width: 22px; height: 22px; border-radius: 50%; background: var(--accent); color: var(--surface); font: 700 13px/22px var(--sans); text-align: center; }

.risks { display: grid; gap: 10px; }
.risk { display: flex; gap: 12px; align-items: flex-start; background: var(--peach); border-radius: 14px; padding: 14px 16px; }
.risk .mark { flex: none; width: 22px; height: 22px; border-radius: 50%; border: 2px solid var(--warn-ink); color: var(--warn-ink); font: 700 13px/18px var(--sans); text-align: center; margin-top: 1px; }
.risk p { min-width: 0; }

.questions { display: grid; grid-template-columns: repeat(auto-fit, minmax(min(100%, 300px), 1fr)); gap: 10px; }
.q { display: flex; gap: 10px; background: var(--lilac); border-radius: 14px; padding: 14px 16px; }
.q .mark { flex: none; font: 600 30px/0.9 var(--hand); color: var(--accent); }
.q p { min-width: 0; }

.points { display: grid; gap: 12px; }
.points li { position: relative; padding-left: 22px; }
.points li::before { content: ""; position: absolute; left: 2px; top: .62em; width: 8px; height: 8px; border-radius: 50%; background: var(--accent); }
.plain { display: grid; gap: 8px; padding-left: 20px; list-style: disc; }
blockquote { margin: 0; padding: 4px 0 4px 44px; position: relative; font-size: 18px; line-height: 1.5; }
blockquote::before { content: "\\201C"; position: absolute; left: 0; top: -10px; font: 600 64px/1 var(--hand); color: var(--accent); }

.meets { display: grid; gap: 10px; }
.meet { display: flex; gap: 16px; align-items: flex-start; background: var(--surface); border: 1px solid var(--line); border-radius: 14px; padding: 12px 16px; }
.cal { flex: none; width: 58px; border-radius: 10px; overflow: hidden; text-align: center; background: var(--sky); }
.cal span { display: block; background: var(--accent); color: var(--surface); font: 600 11px/1.9 var(--mono); text-transform: uppercase; letter-spacing: .08em; }
.cal b { display: block; font: 700 24px/1.6 var(--sans); }
.mb { display: grid; gap: 2px; min-width: 0; }
.mt { font-weight: 600; }
.add { display: flex; flex-wrap: wrap; gap: 8px; margin-top: 10px; }
.btn { font: 600 13px/1 var(--sans); color: var(--ink); text-decoration: none; border: 1px solid var(--line); background: var(--surface); border-radius: 10px; padding: 9px 12px; }
.btn.primary { background: var(--accent); border-color: var(--accent); color: var(--surface); }
.btn:hover { transform: translateY(-1px); }
.btn:focus-visible { outline: 3px solid var(--mint); outline-offset: 2px; }
.mm { color: var(--muted); font-size: 14px; }

.people { display: grid; grid-template-columns: repeat(auto-fit, minmax(min(100%, 320px), 1fr)); gap: 12px; }
.person { background: var(--surface); border: 1px solid var(--line); border-radius: 16px; padding: 18px; display: grid; gap: 12px; align-content: start; min-width: 0; }
.ph { display: flex; gap: 12px; align-items: flex-start; }
.ph > div { min-width: 0; padding-top: 2px; }
.pn { font-weight: 700; }
.pr { color: var(--muted); font-size: 13.5px; line-height: 1.45; }
.pb { display: grid; gap: 8px; font-size: 15px; }
.pb ul { display: grid; gap: 6px; }
.pb li { position: relative; padding-left: 16px; }
.pb li::before { content: ""; position: absolute; left: 0; top: .7em; width: 6px; height: 2px; background: var(--faint); }
.av { flex: none; width: 40px; height: 40px; border-radius: 50%; display: grid; place-content: center; font: 700 14px/1 var(--sans); color: var(--ink); }
.av.sm { width: 20px; height: 20px; font-size: 9px; }
.t0 { background: var(--mint); } .t1 { background: var(--butter); } .t2 { background: var(--lilac); } .t3 { background: var(--peach); } .t4 { background: var(--sky); }
.chip .av { background: var(--surface); }

.prompt { border-radius: 14px; overflow: hidden; background: var(--code-bg); }
.prh { display: flex; justify-content: space-between; align-items: center; gap: 12px; padding: 10px 12px 10px 16px; color: var(--code-ink); font-weight: 600; font-size: 14px; border-bottom: 1px solid rgba(255,255,255,.08); }
.copy { font: 500 12px/1 var(--mono); color: var(--code-ink); background: rgba(255,255,255,.08); border: 1px solid rgba(255,255,255,.14); border-radius: 8px; padding: 7px 10px; cursor: pointer; }
.copy:hover, .copy:focus-visible { background: rgba(255,255,255,.16); outline: none; }
pre { margin: 0; padding: 14px 16px; overflow-x: auto; color: var(--code-ink); font: 400 13px/1.6 var(--mono); white-space: pre-wrap; }
pre code { background: none; padding: 0; font-size: inherit; color: inherit; }

.empty { margin-top: 44px; padding-top: 18px; border-top: 1px dashed var(--line); color: var(--faint); font-size: 14px; }
footer { margin-top: 28px; color: var(--faint); font-size: 12.5px; }

@media (prefers-reduced-motion: no-preference) {
  .hero, .glance, .sec { animation: rise .5s cubic-bezier(.2,.7,.2,1) both; }
  .glance { animation-delay: .06s; }
  .sec:nth-of-type(1) { animation-delay: .14s; } .sec:nth-of-type(2) { animation-delay: .18s; } .sec:nth-of-type(3) { animation-delay: .22s; }
  @keyframes rise { from { transform: translateY(8px); } to { transform: none; } }
}
@media print {
  body { background: #fff; } .glance, .copy, .add, footer, .scribble { display: none; }
  .sec { break-inside: avoid; } .task, .person, .meet { border-color: #ccc; }
}
`;

/// Ticks persist per note in this browser; Copy on agent prompts.
const js = `
(function () {
  var key = "nikxel:" + location.pathname;
  var saved = {};
  try { saved = JSON.parse(localStorage.getItem(key) || "{}"); } catch (e) {}
  document.querySelectorAll(".task input").forEach(function (box) {
    if (box.id in saved) box.checked = saved[box.id];
    box.addEventListener("change", function () {
      saved[box.id] = box.checked;
      try { localStorage.setItem(key, JSON.stringify(saved)); } catch (e) {}
    });
  });
  document.querySelectorAll(".copy").forEach(function (btn) {
    btn.addEventListener("click", function () {
      var code = btn.closest(".prompt").querySelector("code");
      var done = function () { btn.textContent = "Copied"; setTimeout(function () { btn.textContent = "Copy"; }, 1600); };
      var select = function () { var r = document.createRange(); r.selectNodeContents(code); var s = getSelection(); s.removeAllRanges(); s.addRange(r); };
      if (navigator.clipboard) navigator.clipboard.writeText(code.textContent).then(done, select); else select();
    });
  });
})();
`;
