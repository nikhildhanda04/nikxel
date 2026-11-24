/// The chat's mail decisions, kept free of networking so scripts/check-mail-intent.js
/// can run them: does a message concern mail, is it "send it", what the router model
/// asked for, and the RFC 2822 text a draft is made of. Port of src/MailIntent.swift.

export interface MailDraft {
  to: string;
  cc: string;
  subject: string;
  body: string;
  replyTo: string | null; // Gmail message id being answered
}

export interface MailMessage {
  id: string; threadId: string; from: string; to: string; subject: string; date: string; snippet: string; body: string;
  messageId: string; // RFC Message-ID header, for In-Reply-To
  references: string;
}

export type MailLabelOp = "archive" | "read" | "unread" | "star";

export type MailAction =
  | { kind: "answer" }
  | { kind: "search"; query: string }
  | { kind: "draft"; draft: MailDraft }
  | { kind: "label"; ids: string[]; op: MailLabelOp };

export function looksLikeMail(text: string): boolean {
  return /\b(e-?mails?|mails?|inbox|gmail|repl(y|ies)|draft|archive|unread|starred?|cc|subject)\b/i.test(text);
}

/// The whole message is a go-ahead to send ("send it", "ok, send it now.").
/// Matched here, never by the model: mail only goes out when the user says so.
export function isSendCommand(text: string): boolean {
  return /^((ok(ay)?|yes|yep|sure|great|looks good)[,.!]?\s+)*send(\s+(it|that|this|the\s+(draft|mail|email)))?(\s+now)?[.!]*$/i.test(text.trim());
}

function ymd(d: Date): string {
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`;
}

export function routerPrompt(request: string, context: string, history: { q: string; a: string }[], today: Date): string {
  let p = `You are the user's desk avatar deciding what to do with a message about their email. Today is ${ymd(today)}.
The notes below include "### mail" lines like "- [<id>] sender · subject · date: preview".
Reply with ONE JSON object and nothing else:
{"action":"answer"} — the notes already answer it.
{"action":"search","query":"<Gmail search, e.g. from:piyush invoice newer_than:60d>"} — it needs mail not in the notes.
{"action":"draft","to":"<email>","cc":"","subject":"...","body":"...","replyTo":"<id or empty>"} — the user wants an email written. ` +
    `For a reply set replyTo to the id being answered and leave to as the sender's address. Write the body in the user's voice, ` +
    `plain text, no placeholders like [Name]; sign off with the user's first name if the notes give it.
{"action":"label","ids":["<id>",...],"op":"archive|read|unread|star"} — archive, mark read/unread or star emails from the notes.

NOTES:
${context}
`;
  for (const h of history) p += `\nUser: ${h.q}\nYou: ${h.a}\n`;
  return p + `\nUser: ${request}`;
}

export function parseAction(reply: string): MailAction {
  const start = reply.indexOf("{"), end = reply.lastIndexOf("}");
  if (start < 0 || end <= start) return { kind: "answer" };
  let obj: Record<string, unknown>;
  try { obj = JSON.parse(reply.slice(start, end + 1)); } catch { return { kind: "answer" }; }
  const s = (k: string) => (typeof obj[k] === "string" ? (obj[k] as string) : "").trim();
  switch (obj.action) {
    case "search":
      return s("query") ? { kind: "search", query: s("query") } : { kind: "answer" };
    case "draft":
      return s("body")
        ? { kind: "draft", draft: { to: s("to"), cc: s("cc"), subject: s("subject"), body: s("body"), replyTo: s("replyTo") || null } }
        : { kind: "answer" };
    case "label": {
      const op = s("op"), ids = Array.isArray(obj.ids) ? obj.ids.filter((x): x is string => typeof x === "string") : [];
      return ["archive", "read", "unread", "star"].includes(op) && ids.length ? { kind: "label", ids, op: op as MailLabelOp } : { kind: "answer" };
    }
    default:
      return { kind: "answer" };
  }
}

/// A draft as Gmail's `raw`: RFC 2822, UTF-8 body in base64, the whole thing base64url.
export function rawMessage(d: MailDraft, inReplyTo: string | null, references: string | null): string {
  const header = (v: string) => (/^[\x00-\x7f]*$/.test(v) ? v : `=?UTF-8?B?${Buffer.from(v, "utf8").toString("base64")}?=`);
  const lines = [`To: ${d.to}`];
  if (d.cc) lines.push(`Cc: ${d.cc}`);
  lines.push(`Subject: ${header(d.subject)}`);
  if (inReplyTo) {
    lines.push(`In-Reply-To: ${inReplyTo}`);
    lines.push(`References: ${[references ?? "", inReplyTo].filter(x => x).join(" ")}`);
  }
  const body = Buffer.from(d.body, "utf8").toString("base64").replace(/.{76}(?=.)/g, "$&\r\n");
  lines.push("MIME-Version: 1.0", "Content-Type: text/plain; charset=UTF-8", "Content-Transfer-Encoding: base64", "", body);
  return Buffer.from(lines.join("\r\n"), "utf8").toString("base64url");
}

export function contextBlock(unread: MailMessage[], recent: MailMessage[]): string {
  const line = (m: MailMessage) => `- [${m.id}] ${m.from} · ${m.subject} · ${m.date}: ${m.snippet.slice(0, 160)}`;
  const parts: string[] = [];
  if (unread.length) parts.push("Unread in the inbox:\n" + unread.map(line).join("\n"));
  if (recent.length) parts.push("Latest in the inbox (newest first):\n" + recent.map(line).join("\n"));
  return parts.length ? "### mail\n" + parts.join("\n\n") : "";
}

export function searchBlock(query: string, ms: MailMessage[]): string {
  return `### mail search: ${query}\n` + (ms.length
    ? ms.map(m => `[${m.id}] From ${m.from} to ${m.to} · ${m.subject} · ${m.date}\n${m.body || m.snippet}`).join("\n\n")
    : "(no matches)");
}
