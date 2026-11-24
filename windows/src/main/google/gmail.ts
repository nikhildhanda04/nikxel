import { cblog } from "../core/diag";
import { GoogleAuth } from "./googleAuth";
import { GoogleSync } from "./googleSync";
import { MailDraft, MailLabelOp, MailMessage, rawMessage } from "./mailIntent";

/// Gmail over REST with the shared Google sign-in, for the avatar chat: the inbox at
/// chat open, a search when the question needs older mail, drafts, sending a draft the
/// user said to send, and archive/read/star. Nothing is stored. Port of src/Gmail.swift.

export const GMAIL_SCOPE = "https://www.googleapis.com/auth/gmail.modify";
const BASE = "https://gmail.googleapis.com/gmail/v1/users/me";

export function isReady(): boolean {
  return GoogleAuth.shared.isAuthorized && GoogleAuth.shared.hasScope(GMAIL_SCOPE);
}

/// JSON in, JSON out; null on any failure (logged).
async function call(method: string, path: string, body: unknown = null): Promise<any | null> {
  let token: string;
  try { token = await GoogleAuth.shared.getAccessToken(); } catch { return null; }
  const { obj, err } = await GoogleSync.post(BASE + path, method, body, token);
  if (err) { cblog(`Gmail: ${method} ${path.slice(0, 60)} -> ${err}`); return null; }
  return obj ?? {};
}

async function ids(query: string, max: number): Promise<string[]> {
  const r = await call("GET", `/messages?maxResults=${max}&q=${encodeURIComponent(query)}`);
  return (r?.messages ?? []).map((m: { id: string }) => m.id);
}

async function fetchAll(list: string[], full: boolean): Promise<MailMessage[]> {
  return (await Promise.all(list.map(id => message(id, full)))).filter((m): m is MailMessage => m !== null);
}

export async function message(id: string, full = false): Promise<MailMessage | null> {
  const fmt = full ? "format=full"
    : "format=metadata&" + ["From", "To", "Subject", "Date", "Message-ID", "References"].map(h => `metadataHeaders=${h}`).join("&");
  const m = await call("GET", `/messages/${encodeURIComponent(id)}?${fmt}`);
  if (!m) return null;
  const h: Record<string, string> = {};
  for (const x of m.payload?.headers ?? []) h[String(x.name).toLowerCase()] = String(x.value);
  return {
    id, threadId: m.threadId ?? "", from: h.from ?? "", to: h.to ?? "", subject: h.subject ?? "(no subject)", date: h.date ?? "",
    snippet: decodeEntities(m.snippet ?? ""), body: full ? trimmed(text(m.payload ?? {})) : "",
    messageId: h["message-id"] ?? "", references: h.references ?? "",
  };
}

export async function inbox(): Promise<{ unread: MailMessage[]; recent: MailMessage[] }> {
  const unread = await ids("in:inbox is:unread", 20);
  const recent = (await ids("in:inbox", 30)).filter(id => !unread.includes(id));
  const all = await fetchAll([...unread, ...recent], false);
  return { unread: all.filter(m => unread.includes(m.id)), recent: all.filter(m => !unread.includes(m.id)) };
}

export async function search(query: string): Promise<MailMessage[]> {
  return fetchAll(await ids(query, 8), true);
}

/// The draft id and its message id (the one Gmail's compose URL takes).
export async function createDraft(d: MailDraft, replyTo: MailMessage | null): Promise<{ draftId: string; messageId: string } | null> {
  const msg: Record<string, string> = { raw: rawMessage(d, replyTo?.messageId || null, replyTo?.references || null) };
  if (replyTo?.threadId) msg.threadId = replyTo.threadId;
  const r = await call("POST", "/drafts", { message: msg });
  return r?.id ? { draftId: r.id, messageId: r.message?.id ?? "" } : null;
}

export async function sendDraft(id: string): Promise<boolean> {
  return (await call("POST", "/drafts/send", { id })) !== null;
}

export async function modify(list: string[], op: MailLabelOp): Promise<boolean> {
  const [add, remove] = op === "archive" ? [[], ["INBOX"]] : op === "read" ? [[], ["UNREAD"]] : op === "unread" ? [["UNREAD"], []] : [["STARRED"], []];
  return (await call("POST", "/messages/batchModify", { ids: list, addLabelIds: add, removeLabelIds: remove })) !== null;
}

// Body text

function text(part: any): string {
  const mime: string = part.mimeType ?? "";
  const parts: any[] = part.parts ?? [];
  if (!parts.length) {
    const data = part.body?.data;
    if (typeof data !== "string") return "";
    const s = Buffer.from(data, "base64url").toString("utf8");
    return mime === "text/html" ? stripHTML(s) : mime.startsWith("text/") ? s : "";
  }
  // Plain text over HTML when a message has both.
  const plain = parts.find(p => p.mimeType === "text/plain");
  if (plain) return text(plain);
  return parts.map(text).find(t => t) ?? "";
}

function stripHTML(s: string): string {
  return decodeEntities(s.replace(/<(style|script)[^>]*>[\s\S]*?<\/\1>/gi, "")
    .replace(/<br\s*\/?>|<\/p>|<\/div>/gi, "\n").replace(/<[^>]+>/g, ""));
}

function decodeEntities(s: string): string {
  return s.replace(/&nbsp;/g, " ").replace(/&amp;/g, "&").replace(/&lt;/g, "<").replace(/&gt;/g, ">")
    .replace(/&quot;/g, "\"").replace(/&#39;/g, "'");
}

/// Up to the quoted history ("On … wrote:" / "> "), blank runs squeezed, ≤3000 chars.
function trimmed(s: string): string {
  const out: string[] = [];
  for (const l of s.split(/\r?\n/)) {
    if (/^On .+wrote:\s*$/.test(l) || l.startsWith(">")) break;
    out.push(l.trim());
  }
  return out.join("\n").replace(/\n{3,}/g, "\n\n").trim().slice(0, 3000);
}
