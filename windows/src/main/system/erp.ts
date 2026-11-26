import { BrowserWindow, session, net } from "electron";
import { cblog } from "../core/diag";
import { readText } from "../core/paths";
import { richHtml } from "../recording/markdown";
import { Settings } from "../core/settings";
import { TwinProfile } from "./twinProfile";
import { chromeUserAgent } from "../whatsapp/chromeWhatsApp";

/// Talks to the company's Odoo ERP over its web JSON-RPC — no API key and no
/// resident browser. A visible Electron window opens exactly once, for the
/// Google sign-in (this server's Cloudflare clears a real Chromium but 403s
/// headless clients); from its session partition we read the Odoo `session_id`
/// cookie, store it, and destroy the window. Every read and write after that is
/// a plain HTTPS call carrying that cookie — so nothing runs in the background.
/// The session lasts months. The Mac equivalent is src/ERP.swift.

export const PARTITION = "persist:nikxel-erp";

/// The connected ERP's origin ("https://erp.example.com"). Forklyft's was the
/// only one before the address became a setting, so it stays the fallback.
export function base(): string { return origin(Settings.erpURL) ?? "https://erp.forklyft.in"; }
function host(): string { return new URL(base()).hostname; }
/// Why the last sign-in didn't connect, for the Connections page.
export let signInProblem = "";

/// What the user typed, as a URL to open: https:// added when there's no scheme.
export function address(input: string): URL | null {
  let s = (input ?? "").trim();
  if (!s || /\s/.test(s)) return null;
  if (!s.includes("://")) s = "https://" + s;
  try {
    const u = new URL(s);
    if (!/^https?:$/.test(u.protocol) || !(u.hostname.includes(".") || u.hostname === "localhost")) return null;
    return u;
  } catch { return null; }
}

/// "erp.example.com" or "https://erp.example.com/odoo/" → "https://erp.example.com".
export function origin(input: string): string | null { return address(input)?.origin ?? null; }

/// A cookie set for the ERP's host or a parent of it (".example.com").
export function cookieIsOurs(domain: string): boolean {
  const d = (domain ?? "").replace(/^\.+|\.+$/g, "").toLowerCase(), h = host();
  return !!d && (h === d || h.endsWith("." + d));
}

/// Forgets the session (the address stays, for reconnecting).
export function disconnect(): void {
  Settings.erpSession = "";
  Settings.erpConnected = false;
  void session.fromPartition(PARTITION).clearStorageData({ storages: ["cookies"] }).catch(() => { /* nothing to clear */ });
}

/// Closes the sign-in window; signIn sees it gone and reports.
export function cancelSignIn(): void { if (win && !win.isDestroyed()) win.close(); }

let win: BrowserWindow | null = null;

function delay(ms: number): Promise<void> { return new Promise(r => setTimeout(r, ms)); }

export function isConnected(): boolean { return Settings.erpConnected && !!Settings.erpSession; }

/// Whether the stored session still logs in right now (a cheap HTTP check).
/// Lets Assign tell a real sign-out apart from a transient hiccup and ask the
/// user to reconnect instead of failing opaquely.
export async function hasLiveSession(): Promise<boolean> {
  if (!Settings.erpSession) return false;
  return ((await sessionUID()) ?? 0) > 0;
}

// MARK: - Session

/// The signed-in user's Odoo uid, or null when logged out or unreachable.
async function sessionUID(): Promise<number | null> {
  const resp = await post("/web/session/get_session_info", {}, 10000);
  const result = resp && (resp.result as Record<string, unknown> | undefined);
  return result && typeof result.uid === "number" ? result.uid : null;
}

/// Clears the session on a confirmed sign-out, so the menu and Assign buttons
/// reflect that the user must reconnect. Only on a real Odoo SessionExpired —
/// never on a transient network failure.
function markDisconnected(): void {
  Settings.erpSession = "";
  Settings.erpConnected = false;
  cblog("ERP: session expired — reconnect needed");
}

/// One Odoo web-JSON-RPC POST carrying the stored session cookie; the decoded
/// JSON object, or null on a transport failure. A browser-like User-Agent plus
/// the `session_id` cookie are all this server's Cloudflare needs (verified).
function post(path: string, params: Record<string, unknown>, timeout: number): Promise<Record<string, unknown> | null> {
  const sid = Settings.erpSession;
  if (!sid) return Promise.resolve(null);
  return new Promise(resolve => {
    const req = net.request({ method: "POST", url: base() + path });
    req.setHeader("Content-Type", "application/json");
    req.setHeader("User-Agent", chromeUserAgent());
    req.setHeader("Cookie", `session_id=${sid}`);
    const timer = setTimeout(() => { try { req.abort(); } catch { /* already done */ } resolve(null); }, timeout);
    req.on("response", res => {
      const chunks: Buffer[] = [];
      res.on("data", c => chunks.push(c as Buffer));
      res.on("end", () => {
        clearTimeout(timer);
        try { resolve(JSON.parse(Buffer.concat(chunks).toString("utf8"))); } catch { resolve(null); }
      });
    });
    req.on("error", () => { clearTimeout(timer); resolve(null); });
    req.write(JSON.stringify({ jsonrpc: "2.0", method: "call", params }));
    req.end();
  });
}

// MARK: - JSON-RPC

/// `model.method(args, kwargs)` through Odoo web JSON-RPC, carrying the stored
/// session cookie — no browser. Returns the decoded result (a bare id for
/// create, a list for search_read, …), or null on error (logged, not thrown).
/// A SessionExpired clears the session so the UI can prompt a reconnect.
async function callKw(model: string, method: string, args: unknown[], kwargs: Record<string, unknown> = {}): Promise<unknown> {
  if (!Settings.erpSession) { cblog(`ERP: ${model}.${method} — not connected`); return null; }
  // Writes can be slow when Odoo fires assignment notifications — give them
  // headroom rather than orphaning a record on a timeout.
  const slow = method === "create" || method === "write" || method === "unlink";
  const resp = await post("/web/dataset/call_kw", { model, method, args, kwargs }, slow ? 30000 : 15000);
  if (!resp) { cblog(`ERP: ${model}.${method} — no response`); return null; }
  const err = resp.error as { code?: number; message?: string; data?: { name?: string } } | undefined;
  if (err) {
    if (err.code === 100 || String(err.data?.name ?? "").includes("SessionExpired")) markDisconnected();
    cblog(`ERP: ${model}.${method} failed — ${err.message || JSON.stringify(err)}`);
    return null;
  }
  return resp.result ?? null;
}

// MARK: - Reads

export interface User { id: number; name: string; email: string; }

/// Internal users a task can be assigned to (res.users, share=false).
export async function assignableUsers(): Promise<User[]> {
  const rows = await callKw("res.users", "search_read", [[["share", "=", false]], ["name", "login"]]);
  if (!Array.isArray(rows)) return [];
  return rows
    .filter((r): r is Record<string, unknown> => !!r && typeof (r as any).id === "number" && !!(r as any).name)
    .map(r => ({ id: r.id as number, name: r.name as string, email: (r.login as string) ?? "" }));
}

/// Open projects a task can be filed under.
export async function projects(): Promise<{ id: number; name: string }[]> {
  const rows = await callKw("project.project", "search_read", [[], ["id", "name"]]);
  if (!Array.isArray(rows)) return [];
  return rows
    .filter((r): r is Record<string, unknown> => !!r && typeof (r as any).id === "number" && !!(r as any).name)
    .map(r => ({ id: r.id as number, name: r.name as string }));
}

/** Names of the projects where the user has a task assigned to them, or assigned one (created it). null when not connected or on failure. */
export async function myProjectNames(): Promise<string[] | null> {
  if (!isConnected()) return null;
  const uid = await sessionUID();
  if (!uid) return null;
  const rows = await callKw("project.task", "search_read", [["|", ["user_ids", "in", [uid]], ["create_uid", "=", uid]], ["project_id"]]);
  if (!Array.isArray(rows)) return null;
  return [...new Set(rows.map(r => (r as any)?.project_id).filter(v => Array.isArray(v) && typeof v[1] === "string").map(v => v[1] as string))].sort();
}

export interface TouchedTask { name: string; project: string; stage: string; deadline: string }

/// The user's tasks written on `day` (local), for the 10pm summary. [] when not connected or on any failure.
export async function tasksTouched(day: Date): Promise<TouchedTask[]> {
  if (!isConnected()) return [];
  const uid = await sessionUID();
  if (!uid) return [];
  const start = new Date(day.getFullYear(), day.getMonth(), day.getDate());
  const end = new Date(day.getFullYear(), day.getMonth(), day.getDate() + 1);
  const utc = (d: Date) => d.toISOString().slice(0, 19).replace("T", " "); // Odoo stores write_date in UTC
  const rows = await callKw("project.task", "search_read",
    [[["user_ids", "in", [uid]], ["write_date", ">=", utc(start)], ["write_date", "<", utc(end)]], ["name", "project_id", "stage_id", "date_deadline"]]);
  if (!Array.isArray(rows)) return [];
  const m2o = (v: unknown) => (Array.isArray(v) && typeof v[1] === "string" ? v[1] : ""); // [id, "Name"] or false
  return rows
    .filter((r): r is Record<string, unknown> => !!r && typeof (r as any).name === "string" && !!(r as any).name)
    .map(r => ({ name: r.name as string, project: m2o(r.project_id), stage: m2o(r.stage_id), deadline: typeof r.date_deadline === "string" ? r.date_deadline : "" }));
}

/// "what's pending in ERP?", "Aarib's open tasks": a question or automation that's about ERP work.
export function asksAboutTasks(text: string): boolean {
  return /\b(erp|forklyft|tasks?|pending|assigned|deadlines?|overdue)\b/i.test(text);
}

/// The open (not closed) tasks the signed-in user can see, newest first, as a
/// context block for chat and automations. "" when not connected or on any failure.
export async function openTasksBlock(limit = 150): Promise<string> {
  if (!isConnected()) return "";
  const rows = await callKw("project.task", "search_read",
    [[["is_closed", "=", false]], ["name", "user_ids", "reviewer_ids", "project_id", "stage_id", "date_deadline", "create_date"]],
    { limit, order: "create_date desc" });
  if (!Array.isArray(rows)) return "";
  const names = new Map((await assignableUsers()).map(u => [u.id, u.name]));
  const m2o = (v: unknown): string => Array.isArray(v) && typeof v[1] === "string" ? v[1] : "";
  const day = (v: unknown): string => typeof v === "string" ? v.slice(0, 10) : "";
  const lines = rows.flatMap((r: any) => {
    if (!r || typeof r.name !== "string" || !r.name) return [];
    const who = (Array.isArray(r.user_ids) ? r.user_ids : []).map((id: number) => names.get(id)).filter(Boolean).join(", ");
    const parts = [r.name, "for: " + (who || "nobody")];
    // reviewer_ids is a many2one here despite the name: [id, "Name"] or false.
    for (const [label, value] of [["reviewer: ", m2o(r.reviewer_ids)], ["project: ", m2o(r.project_id)],
                                  ["stage: ", m2o(r.stage_id)], ["due ", day(r.date_deadline)]]) if (value) parts.push(label + value);
    parts.push("created " + day(r.create_date));
    return ["- " + parts.join(" · ")];
  });
  if (!lines.length) return "";
  return `### ERP: open tasks (live, read just now; the ${lines.length} newest)\n` + lines.join("\n");
}

// MARK: - Tasks

export async function createTask(title: string, descriptionHTML: string, assigneeUserID: number | null, deadline: string | null, projectID: number | null = null, reviewerUserID: number | null = null): Promise<number | null> {
  const vals: Record<string, unknown> = { name: title, description: descriptionHTML };
  if (assigneeUserID != null) vals.user_ids = [[6, 0, [assigneeUserID]]]; // many2many replace
  if (reviewerUserID != null) vals.reviewer_ids = reviewerUserID;          // Forklyft's own field: one user
  if (projectID != null) vals.project_id = projectID;
  if (deadline) vals.date_deadline = deadline; // "YYYY-MM-DD HH:MM:SS"
  const id = await callKw("project.task", "create", [vals]);
  return typeof id === "number" ? id : null;
}

export function taskURL(id: number): string { return `${base()}/web#id=${id}&model=project.task&view_type=form`; }

// === Chat-initiated tasks ===
// The avatar chat can create a task too, drafting it from the user's request
// plus the recent meetings/WhatsApp/projects it already has in context — the
// same createTask path the meeting summary's "Assign" button uses.

/// Does this chat message ask to create a task? A creation verb within a few
/// words of "task" — "make a task", "create an ERP task", "add a new task" —
/// or "draft a task" / "assign an ERP task" said outright ("draft a nudge for each task" isn't one).
/// Questions about existing tasks ("what tasks did I create") don't match.
export function looksLikeTaskRequest(text: string): boolean {
  return /\b(make|create|add|new|log|raise|set ?up)\b[^.?!\n]{0,40}\btasks?\b|\b(draft|assign)\s+(a|an|the|this)\s+((new|erp|forklyft)\s+)*task\b/i.test(text);
}

/// A task drafted by the chat agent from the request plus context.
export interface TaskDraft { title: string; body: string; assignee: string | null; project: string | null; due: string | null; reviewer?: string | null; }

/// The prompt that turns a chat request + context into one TaskDraft as JSON.
export function taskDraftPrompt(request: string, context: string, today: Date): string {
  const d = today.toISOString().slice(0, 10);
  return `You turn a request into one ERP task. Reply with ONLY a JSON object — no prose, no code fences:
{"title": string, "body": string, "assignee": string|null, "reviewer": string|null, "project": string|null, "due": string|null}
- title: under 70 chars, imperative.
- body: markdown. Pull the concrete details — what to do, who, which project, any deadline — from the recent meetings, WhatsApp and project notes below when they relate to the request. If nothing relates, write a plain description from the request alone.
- assignee: a person's name if the request or context names who it's for, else null.
- reviewer: the person's name if the request says who reviews it ("keep me i.e. Shreya as the reviewer" → "Shreya"), else null.
- project: a project name if clear from the context, else null.
- due: "YYYY-MM-DD" if a date or relative day is given ("tomorrow", "Friday"), else null. Today is ${d}.

Request: ${request}

Context:
${context}`;
}

/// Parse the agent's reply into a TaskDraft, tolerating code fences and prose.
/// null when there's no object or no title.
export function parseTaskDraft(reply: string): TaskDraft | null {
  const open = reply.indexOf("{"), close = reply.lastIndexOf("}");
  if (open < 0 || close <= open) return null;
  let o: Record<string, unknown>;
  try { o = JSON.parse(reply.slice(open, close + 1)) as Record<string, unknown>; } catch { return null; }
  const s = (k: string): string | null => {
    const v = o[k];
    if (typeof v !== "string") return null;
    const t = v.trim();
    return (!t || t.toLowerCase() === "null") ? null : t;
  };
  const title = s("title");
  if (!title) return null;
  return { title: shortTitle(title), body: s("body") ?? title, assignee: s("assignee"), project: s("project"), due: s("due"), reviewer: s("reviewer") };
}

/// Create a task from a drafted TaskDraft: match the assignee and project names
/// to the live roster, render the body, create the record. Returns the new
/// task's web URL on success, or an error message. Call only with a live session.
export async function createTaskFromDraft(draft: TaskDraft): Promise<{ url?: string; error?: string }> {
  const users = await assignableUsers();
  const uid = draft.assignee ? (matchUser(draft.assignee, users)?.id ?? null) : null;
  const rid = draft.reviewer ? (matchUser(draft.reviewer, users)?.id ?? null) : null;
  let pid: number | null = null;
  if (draft.project) {
    const want = draft.project.toLowerCase();
    pid = (await projects()).find(p => p.name.toLowerCase().includes(want))?.id ?? null;
  }
  const deadline = draft.due ? draft.due + " 17:00:00" : null;
  const descHTML = richHtml(TwinProfile.correct(draft.body));
  const id = await createTask(draft.title, descHTML, uid, deadline, pid, rid);
  if (id == null) return { error: "ERP didn't create the task." };
  cblog(`ERP: chat created task ${id} — ${draft.title.slice(0, 60)}`);
  return { url: taskURL(id) };
}

/// Best-effort match of an action-item assignee name to an internal user.
export function matchUser(name: string, users: User[]): User | null {
  const n = name.toLowerCase().replace(/\(me\)/, "").trim();
  if (!n) return null;
  const exact = users.find(u => u.name.toLowerCase() === n);
  if (exact) return exact;
  const first = n.split(" ")[0];
  const fm = users.find(u => u.name.toLowerCase().split(" ")[0] === first);
  if (fm) return fm;
  const hits = users.filter(u => (u.email.toLowerCase().split("@")[0] || "").includes(first));
  return hits.length === 1 ? hits[0] : null;
}

// MARK: - Descriptions

/// A short task title from a long action-item sentence.
export function shortTitle(s: string): string {
  const t = s.trim();
  let head = (t.split(/[.;:]/)[0] || t).trim();
  if (head.length > 70) {
    const cut = head.slice(0, 70);
    const sp = cut.lastIndexOf(" ");
    head = (sp > 0 ? cut.slice(0, sp) : cut) + "…";
  }
  return head || t.slice(0, 70);
}

/// Task body for a plain (non-code) item: the action split into points under a
/// bold heading, then the meeting context — the structured HTML the ERP shows,
/// instead of two flat paragraphs.
export function taskDescription(item: string, context: string): string {
  let md = "**What to do**\n\n" + bulletize(item);
  if (context) md += `\n**Context**\n\n${context}\n`;
  return richHtml(TwinProfile.correct(md));
}

/// A run-on action item as bullet lines, split on clause breaks ("; ") and
/// newlines so the body reads as points. A single clause stays one bullet.
function bulletize(s: string): string {
  const parts = s.split(/\r?\n/).flatMap(l => l.split("; ")).map(p => p.trim()).filter(Boolean);
  return (parts.length ? parts : [s]).map(p => `- ${p}`).join("\n") + "\n";
}

/// If the meeting's markdown has an "## Agent Prompts" brief whose task matches
/// this item, return it as HTML — the full team-style brief the LLM already
/// wrote at summary time. null when there's no close match.
export function briefFromAgentPrompts(item: string, mdPath: string): string | null {
  const md = readText(mdPath);
  if (!md) return null;
  const apr = md.indexOf("## Agent Prompts");
  if (apr < 0) return null;
  let section = md.slice(apr + "## Agent Prompts".length);
  const next = section.indexOf("\n## ");
  if (next >= 0) section = section.slice(0, next);
  const prompts: { head: string; body: string }[] = [];
  for (const part of section.split("### ").slice(1)) {
    const nl = part.indexOf("\n");
    if (nl < 0) continue;
    const head = part.slice(0, nl);
    const after = part.slice(nl + 1);
    const open = after.indexOf("```");
    if (open < 0) continue;
    const rest = after.slice(open + 3);
    const close = rest.indexOf("```");
    if (close < 0) continue;
    const body = rest.slice(0, close).trim();
    if (body) prompts.push({ head, body });
  }
  const want = significantWords(item);
  if (!prompts.length || !want.size) return null;
  let best: { score: number; body: string } | null = null;
  for (const p of prompts) {
    const hay = significantWords(p.head + " " + p.body.slice(0, 220));
    let overlap = 0;
    for (const w of want) if (hay.has(w)) overlap++;
    const score = overlap / want.size;
    if (!best || score > best.score) best = { score, body: p.body };
  }
  if (!best || best.score < 0.35) return null;
  return richHtml(best.body);
}

function significantWords(s: string): Set<string> {
  return new Set(s.toLowerCase().split(/[^a-z0-9]+/i).filter(w => w.length >= 4));
}

// MARK: - Sign-in (the one window the user sees)

/// Opens a visible ERP window for the one-time Google sign-in. Polls until the
/// partition holds a logged-in Odoo session, captures its `session_id` cookie,
/// stores it, and destroys the window — from then on every call is plain HTTPS,
/// nothing stays open. Resolves true once connected. Closing the window cancels.
export async function signIn(): Promise<boolean> {
  const ua = chromeUserAgent();
  session.fromPartition(PARTITION).setUserAgent(ua);
  const w = new BrowserWindow({
    width: 1100, height: 800, title: "ERP sign-in — Nikxel", autoHideMenuBar: true,
    webPreferences: { partition: PARTITION, contextIsolation: true, nodeIntegration: false, sandbox: true, spellcheck: false },
  });
  win = w;
  w.on("closed", () => { if (win === w) win = null; });
  w.webContents.setUserAgent(ua);
  signInProblem = "";
  w.loadURL(Settings.erpURL || `${base()}/odoo/`, { userAgent: ua }).catch(e => cblog(`ERP: load failed — ${e}`));
  cblog("ERP: opened sign-in window");
  await delay(1500);
  const deadline = Date.now() + 180000;
  while (Date.now() < deadline) {
    if (!win || w.isDestroyed()) { cblog("ERP: sign-in window closed — cancelled"); Settings.erpSession = ""; signInProblem = "The window closed before you signed in."; return false; }
    // captureSession stores whatever cookie the partition holds (anonymous at
    // first); sessionUID over HTTP confirms it's logged in.
    if (await captureSession()) {
      const uid = await sessionUID();
      if (uid && uid > 0) {
        cblog(`ERP: signed in (uid ${uid})`);
        Settings.erpConnected = true;
        win = null;
        if (!w.isDestroyed()) w.destroy();
        return true;
      }
    }
    await delay(2000);
  }
  cblog("ERP: sign-in timed out");
  signInProblem = "No sign-in after 3 minutes. Check it’s your ERP’s address, then try again.";
  Settings.erpSession = "";
  win = null;
  if (!w.isDestroyed()) w.destroy();
  return false;
}

/// Read the Odoo `session_id` cookie from the sign-in partition and store it.
/// false until the partition actually has one.
async function captureSession(): Promise<boolean> {
  try {
    const cookies = await session.fromPartition(PARTITION).cookies.get({ name: "session_id" });
    const c = cookies.find(ck => cookieIsOurs(ck.domain ?? "") && ck.value);
    if (c?.value) { Settings.erpSession = c.value; return true; }
  } catch (e) { cblog(`ERP: cookie read failed — ${e}`); }
  return false;
}

/// Nothing to start — reads and writes are plain HTTPS with the stored cookie;
/// no browser runs in the background. Kept for the launch call site.
export function startIfConnected(): void { /* no resident browser */ }
