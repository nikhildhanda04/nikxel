/// Minimal Markdown for what the note prompts actually emit: headings, bullet
/// and numbered lists (with `- [ ]` task boxes and nesting), bold/italic/code,
/// links, fenced code, rules, quotes, pipe tables and paragraphs. Not a general
/// Markdown implementation. Parsed once into blocks so the HTML (PDF) and the
/// Word writer render the same structure.

export type Inline =
  | { t: "text"; s: string }
  | { t: "code"; s: string }
  | { t: "b"; c: Inline[] }
  | { t: "i"; c: Inline[] }
  | { t: "link"; href: string; c: Inline[] };

export interface ListItem { ordered: boolean; level: number; num: number; check: boolean | null; inl: Inline[]; text: string }

export type Block =
  | { t: "h"; level: number; inl: Inline[] }
  | { t: "p"; inl: Inline[]; text: string }
  | { t: "quote"; inl: Inline[] }
  | { t: "list"; items: ListItem[] }
  | { t: "code"; text: string }
  | { t: "hr" }
  | { t: "table"; header: Inline[][]; rows: Inline[][][] };

// MARK: - Inline

/// Index of the closing `marker` at or after `from`, skipping code spans (and,
/// for single `*`, whole `**bold**` runs so they don't close an italic early).
function findClose(s: string, marker: string, from: number): number {
  let j = from;
  while (j < s.length) {
    if (s[j] === "\\") { j += 2; continue; }
    if (s[j] === "`") {
      let n = 1;
      while (s[j + n] === "`") n++;
      const end = s.indexOf("`".repeat(n), j + n);
      j = end < 0 ? j + n : end + n;
      continue;
    }
    if (marker === "*" && s.startsWith("**", j)) {
      const end = findClose(s, "**", j + 2);
      j = end < 0 ? j + 2 : end + 2;
      continue;
    }
    if (s.startsWith(marker, j)) {
      // A closer can't follow whitespace ("2 * 3 * 4" is not italic).
      if (marker === "*" && /\s/.test(s[j - 1] ?? " ")) { j++; continue; }
      return j;
    }
    j++;
  }
  return -1;
}

/// Unmatched markers are left as literal text rather than swallowing the
/// rest of the line.
export function parseInline(s: string): Inline[] {
  const out: Inline[] = [];
  let buf = "";
  const flush = () => { if (buf) { out.push({ t: "text", s: buf }); buf = ""; } };
  let i = 0;
  while (i < s.length) {
    const c = s[i];
    if (c === "\\" && i + 1 < s.length && /[\\`*_[\]()#+\-.!|<>]/.test(s[i + 1])) {
      buf += s[i + 1]; i += 2; continue;
    }
    if (c === "`") {
      let n = 1;
      while (s[i + n] === "`") n++;
      const fence = "`".repeat(n);
      const end = s.indexOf(fence, i + n);
      if (end >= 0) {
        flush();
        let code = s.slice(i + n, end);
        if (code.length > 1 && code.startsWith(" ") && code.endsWith(" ")) code = code.slice(1, -1);
        out.push({ t: "code", s: code });
        i = end + n;
      } else { buf += fence; i += n; }
      continue;
    }
    if (s.startsWith("**", i)) {
      const end = findClose(s, "**", i + 2);
      if (end > i + 2) { flush(); out.push({ t: "b", c: parseInline(s.slice(i + 2, end)) }); i = end + 2; }
      else { buf += "**"; i += 2; }
      continue;
    }
    if (c === "*" && i + 1 < s.length && !/\s/.test(s[i + 1])) {
      const end = findClose(s, "*", i + 1);
      if (end > i + 1) { flush(); out.push({ t: "i", c: parseInline(s.slice(i + 1, end)) }); i = end + 1; continue; }
    }
    if (c === "[") {
      const m = /^\[([^\]]*)\]\(([^)\s]+)(?:\s+"[^"]*")?\)/.exec(s.slice(i));
      if (m) { flush(); out.push({ t: "link", href: m[2], c: parseInline(m[1]) }); i += m[0].length; continue; }
    }
    if (c === "<") {
      const m = /^<((?:https?:\/\/|mailto:)[^>\s]+)>/.exec(s.slice(i));
      if (m) { flush(); out.push({ t: "link", href: m[1], c: [{ t: "text", s: m[1] }] }); i += m[0].length; continue; }
    }
    buf += c;
    i++;
  }
  flush();
  return out;
}

/// Only web and mail links become clickable; anything else stays text.
export function safeHref(href: string): string | null {
  return /^(https?:|mailto:)/i.test(href) ? href : null;
}

// MARK: - Blocks

const TABLE_SEP = /^\|?\s*:?-{2,}:?\s*(\|\s*:?-{2,}:?\s*)*\|?\s*$/;

function splitRow(line: string): string[] {
  let l = line.trim();
  if (l.startsWith("|")) l = l.slice(1);
  if (l.endsWith("|") && !l.endsWith("\\|")) l = l.slice(0, -1);
  const cells: string[] = [];
  let cur = "";
  for (let i = 0; i < l.length; i++) {
    if (l[i] === "\\" && l[i + 1] === "|") { cur += "|"; i++; continue; }
    if (l[i] === "|") { cells.push(cur.trim()); cur = ""; continue; }
    cur += l[i];
  }
  cells.push(cur.trim());
  return cells;
}

function indentWidth(ws: string): number {
  let w = 0;
  for (const ch of ws) w += ch === "\t" ? 4 : 1;
  return w;
}

export function parseMarkdown(markdown: string): Block[] {
  const blocks: Block[] = [];
  const lines = markdown.replace(/^﻿/, "").split(/\r\n|\r|\n/);
  let list: ListItem[] | null = null;
  const closeList = () => { if (list) { blocks.push({ t: "list", items: list }); list = null; } };

  for (let i = 0; i < lines.length; i++) {
    const rawLine = lines[i];
    const line = rawLine.trim();

    if (line.startsWith("```")) {
      closeList();
      const body: string[] = [];
      i++;
      while (i < lines.length && !lines[i].trim().startsWith("```")) body.push(lines[i++]);
      blocks.push({ t: "code", text: body.join("\n") });
      continue;
    }

    if (!line) { closeList(); continue; }

    const heading = /^(#{1,6})\s*(.*?)\s*#*$/.exec(line);
    if (heading && line.startsWith("#")) {
      closeList();
      blocks.push({ t: "h", level: heading[1].length, inl: parseInline(heading[2]) });
      continue;
    }
    if (/^(-{3,}|\*{3,}|_{3,})$/.test(line.replace(/\s+/g, ""))) {
      closeList();
      blocks.push({ t: "hr" });
      continue;
    }
    const bullet = /^(\s*)[-*+]\s+(.*)$/.exec(rawLine);
    const numbered = bullet ? null : /^(\s*)(\d{1,9})[.)]\s+(.*)$/.exec(rawLine);
    if (bullet || numbered) {
      const indent = indentWidth((bullet ?? numbered)![1]);
      let text = bullet ? bullet[2] : numbered![3];
      let check: boolean | null = null;
      const box = /^\[([ xX])\]\s+(.*)$/.exec(text);
      if (box) { check = box[1] !== " "; text = box[2]; }
      list ??= [];
      list.push({
        ordered: !!numbered,
        level: Math.min(3, Math.floor(indent / 2)),
        num: numbered ? Number(numbered[2]) : 0,
        check,
        inl: parseInline(text),
        text,
      });
      continue;
    }
    if (line.startsWith("|") && i + 1 < lines.length && TABLE_SEP.test(lines[i + 1].trim())) {
      closeList();
      const header = splitRow(line).map(parseInline);
      const rows: Inline[][][] = [];
      i += 2;
      while (i < lines.length && lines[i].trim().startsWith("|")) rows.push(splitRow(lines[i++]).map(parseInline));
      i--;
      blocks.push({ t: "table", header, rows });
      continue;
    }
    closeList();
    if (line.startsWith(">")) { blocks.push({ t: "quote", inl: parseInline(line.replace(/^>\s?/, "")) }); continue; }
    blocks.push({ t: "p", inl: parseInline(line), text: line });
  }
  closeList();
  return blocks;
}

// MARK: - HTML

export function escapeHtml(text: string): string {
  return text.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
}

function inlineHtml(inl: Inline[]): string {
  return inl.map(n => {
    switch (n.t) {
      case "text": return escapeHtml(n.s);
      case "code": return `<code>${escapeHtml(n.s)}</code>`;
      case "b": return `<strong>${inlineHtml(n.c)}</strong>`;
      case "i": return `<em>${inlineHtml(n.c)}</em>`;
      case "link": {
        const href = safeHref(n.href);
        return href ? `<a href="${escapeHtml(href)}">${inlineHtml(n.c)}</a>` : inlineHtml(n.c);
      }
    }
  }).join("");
}

/// One line of Markdown text as escaped inline HTML.
export function inline(text: string): string { return inlineHtml(parseInline(text)); }

/// "- None." / "None — no tasks came out of this meeting."
export function isNone(text: string): boolean {
  const t = text.toLowerCase().trim();
  return t === "none" || t === "none." || t.startsWith("none —") || t.startsWith("none -");
}

/// "**Task** — Owner: Vikas — Due: Not specified" -> { text: "**Task**", fields:
/// [["Owner", "Vikas"], ["Due", "Not specified"]] }. Parts that aren't fields stay text.
export function splitFields(item: string): { text: string; fields: { key: string; value: string }[] } {
  const text: string[] = [], fields: { key: string; value: string }[] = [];
  item.split(" — ").forEach((part, i) => {
    const colon = part.indexOf(":");
    const key = colon < 0 ? "" : part.slice(0, colon).trim();
    const value = colon < 0 ? "" : part.slice(colon + 1).trim();
    if (i > 0 && key && key.length <= 12 && value && /^[\p{L} ]+$/u.test(key)) fields.push({ key, value });
    else text.push(part);
  });
  return { text: text.join(" — "), fields };
}

/// A field as a chip; "Unassigned" / "Not specified" greyed out.
export function chip(key: string, value: string): string {
  const unset = ["not specified", "unassigned"].includes(value.toLowerCase());
  const cls = `chip ${key.toLowerCase().replace(/ /g, "-")}${unset ? " unset" : ""}`;
  return `<span class="${escapeHtml(cls)}">&nbsp;<span class="k">${escapeHtml(key)}</span>&nbsp; ${inline(value)}&nbsp;</span>`;
}

function fields(item: string): string {
  const { text, fields } = splitFields(item);
  const body = inline(text);
  return fields.length ? `${body}<br/>${fields.map(f => chip(f.key, f.value)).join(" ")}` : body;
}

/// Lists, with task lines in their own ul.tasks and "None." items fading out
/// of the list as a paragraph.
function listHtml(items: ListItem[]): string {
  let out = "";
  type Kind = "ul" | "ol" | "tasks";
  const stack: { kind: Kind; level: number }[] = [];
  const close = (k: Kind) => `</${k === "ol" ? "ol" : "ul"}>\n`;
  for (const it of items) {
    if (isNone(it.text)) {
      while (stack.length) out += close(stack.pop()!.kind);
      out += `<p class="none">${inlineHtml(it.inl)}</p>\n`;
      continue;
    }
    const kind: Kind = it.ordered ? "ol" : it.check === null ? "ul" : "tasks";
    while (stack.length && stack[stack.length - 1].level > it.level) out += close(stack.pop()!.kind);
    const top = stack[stack.length - 1];
    if (top && top.level === it.level && top.kind !== kind) out += close(stack.pop()!.kind);
    // Browsers indent a list nested straight inside another list, so a deeper
    // item just opens a new one; skipped levels collapse into one step.
    if (!stack.length || stack[stack.length - 1].level < it.level) {
      const start = it.ordered && it.num !== 1 ? ` start="${it.num}"` : "";
      out += kind === "tasks" ? '<ul class="tasks">\n' : `<${kind}${start}>\n`;
      stack.push({ kind, level: it.level });
    }
    if (it.check === null) out += `<li>${it.ordered ? inlineHtml(it.inl) : fields(it.text)}</li>\n`;
    else out += `<li class="task"><span class="box">${it.check ? "☑" : "☐"}</span>&nbsp; ${fields(it.text)}</li>\n`;
  }
  while (stack.length) out += close(stack.pop()!.kind);
  return out;
}

/// "yyyy-MM-dd HH:mm" / "yyyy-MM-dd" as a local date, or null. Shared with notePage.ts.
export function parseLocalDate(s: string, withTime: boolean): Date | null {
  const m = (withTime ? /^(\d{4})-(\d{2})-(\d{2}) (\d{2}):(\d{2})$/ : /^(\d{4})-(\d{2})-(\d{2})$/).exec(s.trim());
  if (!m) return null;
  const d = new Date(+m[1], +m[2] - 1, +m[3], +(m[4] ?? 0), +(m[5] ?? 0));
  return d.getMonth() === +m[2] - 1 && d.getDate() === +m[3] ? d : null;
}

/// Date pieces in the system locale ("Thursday", "November", "13:21").
export const fmt = {
  weekday: (d: Date, style: "long" | "short" = "long") => d.toLocaleDateString(undefined, { weekday: style }),
  month: (d: Date, style: "long" | "short" = "long") => d.toLocaleDateString(undefined, { month: style }),
  time: (d: Date) => d.toLocaleTimeString(undefined, { timeStyle: "short" }),
};

/// "Meeting — 2026-11-12 13:21" -> an eyebrow ("Minutes of meeting") over
/// a readable date. Anything else is shown as-is.
function header(title: string): string {
  const parts = title.split(" — ");
  if (parts.length !== 2) return `<h1>${inline(title)}</h1>\n`;
  const kind = parts[0] === "Meeting" ? "Minutes of meeting" : parts[0];
  const d = parseLocalDate(parts[1], true);
  if (!d) return `<p class="eyebrow">${escapeHtml(kind)}</p>\n<h1>${inline(parts[1])}</h1>\n`;
  const day = `${fmt.weekday(d)}, ${d.getDate()} ${fmt.month(d)} ${d.getFullYear()}`;
  return `<p class="eyebrow">${escapeHtml(kind)}</p>\n<h1>${escapeHtml(day)}</h1>\n<p class="meta">${escapeHtml(fmt.time(d))}</p>\n`;
}

/// The note as a standalone, styled HTML page (what the PDF is printed from).
/// Styled to read as a document rather than a text dump: the title becomes
/// an eyebrow + date, the first Summary line a lead, "— Owner: X" style
/// fields chips, and "None." sections fade out.
export function markdownToHtml(markdown: string, fallbackTitle = "Nikxel"): string {
  let body = "", title = fallbackTitle, section = "", inSection = false, leadDone = false;
  for (const b of parseMarkdown(markdown)) {
    switch (b.t) {
      case "h": {
        const text = headingText(b.inl);
        if (b.level === 1) { title = text; body += header(text); }
        else if (b.level === 2) {
          if (inSection) body += "</section>\n";
          inSection = true;
          section = text.toLowerCase();
          body += `<section>\n<h2>${inlineHtml(b.inl)}</h2>\n`;
        } else body += `<h${b.level}>${inlineHtml(b.inl)}</h${b.level}>\n`;
        break;
      }
      case "p": {
        if (isNone(b.text)) { body += `<p class="none">${inlineHtml(b.inl)}</p>\n`; break; }
        // The opening line of Summary is the one most people stop at.
        // Older prompts wrote Summary as one long paragraph; that's not a lead.
        const lead = section === "summary" && !leadDone && b.text.length <= 240;
        if (section === "summary") leadDone = true;
        // "**Name:** what they said" / "**Name**" -- a speaker heading.
        const speaker = b.text.startsWith("**") && (b.text.endsWith("**") || b.text.includes(":**"));
        body += `<p${lead ? ' class="lead"' : speaker ? ' class="who"' : ""}>${inlineHtml(b.inl)}</p>\n`;
        break;
      }
      case "quote": body += `<blockquote>${inlineHtml(b.inl)}</blockquote>\n`; break;
      case "hr": body += "<hr/>\n"; break;
      case "code": body += `<pre>${escapeHtml(b.text)}</pre>\n`; break;
      case "list": body += listHtml(b.items); break;
      case "table": {
        body += "<table>\n<thead><tr>" + b.header.map(c => `<th>${inlineHtml(c)}</th>`).join("") + "</tr></thead>\n<tbody>\n";
        for (const r of b.rows) body += "<tr>" + r.map(c => `<td>${inlineHtml(c)}</td>`).join("") + "</tr>\n";
        body += "</tbody></table>\n";
        break;
      }
    }
  }
  if (inSection) body += "</section>\n";
  return `<!doctype html>
<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>${escapeHtml(title)}</title><style>${css}</style></head><body><main>
${body}</main></body></html>
`;
}

/// A heading's plain text (markers dropped), for the title and section key.
function headingText(inl: Inline[]): string {
  return inl.map(n => n.t === "text" || n.t === "code" ? n.s : headingText(n.c)).join("");
}

/// Website palette: paper, ink, the green accent, and the pastel chips. Mac
/// fonts swapped for Segoe UI / Consolas.
const css = `
body { margin: 0; background: #f6faf5; color: #25302a; font-family: "Segoe UI", "Helvetica Neue", Helvetica, Arial, sans-serif; font-size: 11pt; line-height: 1.55; }
main { max-width: 760px; margin: 32px auto; padding: 40px 48px; background: #ffffff; border: 1px solid #d7e9d6; border-radius: 18px; }
.eyebrow { color: #23864d; font-size: 8.5pt; font-weight: 700; letter-spacing: 1.5pt; text-transform: uppercase; margin: 0 0 4pt 0; }
h1 { font-size: 22pt; line-height: 1.2; font-weight: 700; margin: 0 0 6pt 0; }
.meta { color: #5c6a60; font-size: 10pt; margin: 0 0 8pt 0; }
section { margin-top: 22pt; }
h2 { color: #23864d; font-size: 9pt; font-weight: 700; letter-spacing: 1.2pt; text-transform: uppercase; border-top: 1px solid #d7e9d6; padding-top: 12pt; margin: 22pt 0 8pt 0; break-after: avoid; }
h3 { font-size: 12pt; margin: 14pt 0 6pt 0; break-after: avoid; }
p { margin: 0 0 8pt 0; }
.lead { font-size: 13pt; line-height: 1.5; font-weight: 600; }
.who { margin-top: 12pt; }
.who strong { color: #23864d; }
ul, ol { margin: 0 0 8pt 0; padding-left: 18pt; }
li { margin: 0 0 5pt 0; }
ul.tasks { list-style-type: none; padding-left: 0; }
.task { margin: 0 0 9pt 0; padding: 8pt 12pt; background: #f6faf5; border-radius: 10px; break-inside: avoid; }
.box { color: #23864d; font-size: 12pt; }
.chip { font-size: 8.5pt; font-weight: 600; background: #d6f3e3; border-radius: 99px; padding: 1pt 7pt; white-space: nowrap; }
.chip .k { color: #5c6a60; font-weight: 500; }
.chip.due, .chip.when { background: #fff3c4; }
.chip.duration { background: #e8ddff; }
.chip.with { background: #ffe6d3; }
.chip.unset { background: #eef2ee; color: #5c6a60; }
.none { color: #8a968d; font-style: italic; }
code { font-family: Consolas, "Cascadia Mono", monospace; font-size: 9.5pt; background: #f6faf5; border-radius: 4px; padding: 0 3pt; }
pre { font-family: Consolas, "Cascadia Mono", monospace; font-size: 9pt; line-height: 1.5; background: #f6faf5; border: 1px solid #d7e9d6; border-radius: 10px; padding: 10pt 12pt; white-space: pre-wrap; word-wrap: break-word; }
hr { border: 0; border-top: 1px solid #d7e9d6; }
blockquote { margin: 0 0 8pt 0; padding-left: 10pt; border-left: 3px solid #d7e9d6; color: #5c6a60; }
table { border-collapse: collapse; margin: 6pt 0 10pt 0; } th, td { border: 1px solid #d7e9d6; padding: 3pt 6pt; text-align: left; vertical-align: top; }
th { background: #f6faf5; }
a { color: #23864d; }
@media print { body { background: #fff; } main { border: 0; margin: 0; padding: 0; max-width: none; } }
`;
