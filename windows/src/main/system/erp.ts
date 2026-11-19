import { app, BrowserWindow, session } from "electron";
import { cblog } from "../core/diag";
import { readText } from "../core/paths";
import { richHtml } from "../recording/markdown";
import { Settings } from "../core/settings";
import { CDPClient } from "../whatsapp/cdpClient";
import { chromeUserAgent } from "../whatsapp/chromeWhatsApp";

/// Reads the company's Odoo ERP through a hidden Electron BrowserWindow with
/// its own persistent session partition — the Windows equivalent of the Mac
/// app's separate Chrome (src/ERP.swift). A real Chromium UA so the server's
/// Cloudflare lets it through; the window is shown only for the one-time
/// sign-in, then hidden (not destroyed) so the Odoo session stays live. Every
/// read and the task create go through Odoo's web JSON-RPC, evaluated in the
/// logged-in page — no HTML scraping, no keychain.

const BASE = "https://erp.forklyft.in";
const PARTITION = "persist:nikxel-erp";
const ODOO_URL = `${BASE}/odoo/`;

let win: BrowserWindow | null = null;
let cdp: CDPClient | null = null;
let quitting = false;
let quitHooked = false;

function createWindow(): BrowserWindow {
  const ua = chromeUserAgent();
  const ses = session.fromPartition(PARTITION);
  ses.setUserAgent(ua);

  const w = new BrowserWindow({
    width: 1100,
    height: 800,
    show: false,
    title: "Forklyft ERP — Nikxel",
    autoHideMenuBar: true,
    webPreferences: {
      partition: PARTITION,
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true,
      spellcheck: false,
      // Keep timers/rendering alive while hidden so background reads work.
      backgroundThrottling: false,
    },
  });
  w.webContents.setUserAgent(ua);
  w.webContents.setBackgroundThrottling(false);

  // Closing hides: the session and the page stay alive while Nikxel runs.
  // Only a real quit destroys it.
  if (!quitHooked) {
    quitHooked = true;
    app.on("before-quit", () => { quitting = true; });
  }
  w.on("close", e => { if (quitting) return; e.preventDefault(); w.hide(); });
  w.on("closed", () => { if (win === w) { win = null; cdp = null; } });
  w.webContents.on("render-process-gone", () => {
    if (!w.isDestroyed()) w.loadURL(ODOO_URL, { userAgent: ua }).catch(() => {});
  });

  cdp = new CDPClient(w.webContents, ua);
  cdp.attach();
  w.loadURL(ODOO_URL, { userAgent: ua }).catch(e => cblog(`ERP: load failed — ${e}`));
  cblog("ERP: opened ERP window");
  win = w;
  return w;
}

/// The window, created on demand. `force` creates it even when ERP was never
/// connected — only for the explicit sign-in action.
function ensureWindow(force: boolean): BrowserWindow | null {
  if (win && !win.isDestroyed()) return win;
  if (!force && !Settings.erpConnected) return null;
  try {
    return createWindow();
  } catch (e) {
    cblog(`ERP: couldn't create window — ${e}`);
    return null;
  }
}

function ensureCDP(): CDPClient | null {
  if (!ensureWindow(false)) return null;
  return cdp;
}

export function isConnected(): boolean { return Settings.erpConnected; }

function delay(ms: number): Promise<void> { return new Promise(r => setTimeout(r, ms)); }

// MARK: - Session

async function sessionUID(): Promise<number | null> {
  const c = ensureCDP();
  if (!c) return null;
  const js = `fetch("${BASE}/web/session/get_session_info",{method:"POST",headers:{"Content-Type":"application/json"},` +
    `body:JSON.stringify({jsonrpc:"2.0",method:"call",params:{}})}).then(r=>r.json())` +
    `.then(j=>JSON.stringify({uid:(j.result&&j.result.uid)||null})).catch(e=>JSON.stringify({uid:null}))`;
  const out = await c.eval(js);
  if (!out) return null;
  try { const o = JSON.parse(out) as { uid?: unknown }; return typeof o.uid === "number" ? o.uid : null; } catch { return null; }
}

// MARK: - JSON-RPC

/// `model.method(args, kwargs)` through Odoo web JSON-RPC, as the logged-in
/// page. Returns the decoded result, or null on error (logged, not thrown).
async function callKw(model: string, method: string, args: unknown[], kwargs: Record<string, unknown> = {}): Promise<unknown> {
  const c = ensureCDP();
  if (!c) { cblog(`ERP: ${model}.${method} — no browser session`); return null; }
  const body = JSON.stringify({ jsonrpc: "2.0", method: "call", params: { model, method, args, kwargs } });
  const lit = JSON.stringify(body); // body embedded as a JS string literal
  const js = `fetch("${BASE}/web/dataset/call_kw",{method:"POST",headers:{"Content-Type":"application/json"},body:${lit}})` +
    `.then(r=>r.json()).then(j=>JSON.stringify(j.error?{__erp_error:j.error.data&&j.error.data.message||j.error.message}:(j.result??null)))` +
    `.catch(e=>JSON.stringify({__erp_error:String(e)}))`;
  // Writes can be slow when Odoo fires assignment notifications — give them
  // headroom rather than orphaning a record on a timeout.
  const slow = method === "create" || method === "write" || method === "unlink";
  const out = await c.eval(js, slow ? 30000 : 10000);
  if (!out) { cblog(`ERP: ${model}.${method} — no response (timed out)`); return null; }
  let decoded: unknown;
  try { decoded = JSON.parse(out); } catch { cblog(`ERP: ${model}.${method} — unreadable response`); return null; }
  if (decoded && typeof decoded === "object" && "__erp_error" in (decoded as Record<string, unknown>)) {
    cblog(`ERP: ${model}.${method} failed — ${(decoded as Record<string, unknown>).__erp_error}`);
    return null;
  }
  return decoded;
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

// MARK: - Tasks

export async function createTask(title: string, descriptionHTML: string, assigneeUserID: number | null, deadline: string | null): Promise<number | null> {
  const vals: Record<string, unknown> = { name: title, description: descriptionHTML };
  if (assigneeUserID != null) vals.user_ids = [[6, 0, [assigneeUserID]]]; // many2many replace
  if (deadline) vals.date_deadline = deadline; // "YYYY-MM-DD HH:MM:SS"
  const id = await callKw("project.task", "create", [vals]);
  return typeof id === "number" ? id : null;
}

export function taskURL(id: number): string { return `${BASE}/web#id=${id}&model=project.task&view_type=form`; }

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
  return richHtml(md);
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

/// Opens the ERP window for the one-time sign-in, waits until Odoo reports a
/// logged-in uid, then hides it (keeping the session). Resolves true once
/// connected. Hiding/closing the window cancels.
export async function signIn(): Promise<boolean> {
  const w = ensureWindow(true);
  if (!w) return false;
  w.show();
  w.focus();
  await delay(1500);
  const deadline = Date.now() + 180000;
  while (Date.now() < deadline) {
    if (!win || win.isDestroyed() || !win.isVisible()) { cblog("ERP: sign-in window closed — cancelled"); return false; }
    const uid = await sessionUID();
    if (uid && uid > 0) {
      cblog(`ERP: signed in (uid ${uid})`);
      Settings.erpConnected = true;
      if (win && !win.isDestroyed()) win.hide();
      return true;
    }
    await delay(2000);
  }
  cblog("ERP: sign-in timed out");
  if (win && !win.isDestroyed()) win.hide();
  return false;
}

/// On launch: bring the hidden window up if we were connected before.
export function startIfConnected(): void {
  if (!Settings.erpConnected) return;
  ensureWindow(false);
}
