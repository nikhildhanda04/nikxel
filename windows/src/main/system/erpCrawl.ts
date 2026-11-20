import { BrowserWindow, session } from "electron";
import { cblog } from "../core/diag";
import { BASE, PARTITION, isConnected, hasLiveSession } from "./erp";
import { ErpContext } from "./erpContext";
import { chromeUserAgent } from "../whatsapp/chromeWhatsApp";

/// Reads the signed-in user's ERP by opening a hidden on-demand window on the
/// SAME partition the ERP sign-in left authenticated (so no cookie capture —
/// the partition already holds the session), walking a bounded set of the ERP's
/// own sections, and grabbing each page's rendered text. Read-only: it
/// navigates and reads innerText; it never submits a form or clicks an action.
/// The window is destroyed before capture() returns — nothing stays resident.
/// Mirrors ErpCrawl.swift.

const MAX_SECTIONS = 8;
const KEEP_MIN = 400; // below this a page is an empty state / error, not content
// Friendly Odoo app slugs worth reading, value-first (apps the install lacks
// return an empty state and get filtered). Employees is an install-specific
// action id and its people already come from ERP.assignableUsers(), so it's omitted.
const ODOO_APPS = ["project", "contacts", "to-do", "crm", "sale", "purchase", "stock", "timesheets"];

function delay(ms: number): Promise<void> { return new Promise(r => setTimeout(r, ms)); }

/// Crawl the connected ERP and fold the result into the sealed ERP facts.
/// Skips (keeping old facts) unless there's a live session.
export async function ingest(runPrompt: (prompt: string, kind: string) => Promise<string>): Promise<void> {
  if (!isConnected() || !(await hasLiveSession())) { cblog("ErpCrawl: ingest skipped — no live ERP session"); return; }
  await ErpContext.ingestWith(capture, runPrompt);
}

/// Bounded sweep of the user's ERP → the captured section texts. [] on any
/// failure (not authenticated, blocked, logged out).
export async function capture(): Promise<string[]> {
  const ua = chromeUserAgent();
  session.fromPartition(PARTITION).setUserAgent(ua);
  let win: BrowserWindow | null = null;
  try {
    win = new BrowserWindow({
      show: false, width: 1400, height: 1000,
      webPreferences: { partition: PARTITION, contextIsolation: true, nodeIntegration: false, sandbox: true },
    });
    win.webContents.setUserAgent(ua);
    await win.loadURL(`${BASE}/odoo/`, { userAgent: ua }).catch(() => { /* SPA loads async; waitForApp handles it */ });
    if (!(await waitForApp(win))) { cblog("ErpCrawl: app didn't load (blocked or logged out)"); return []; }
    const odoo = await evalBool(win, "!!document.querySelector('.o_main_navbar, .o_web_client')");
    const sections = odoo ? await captureOdoo(win) : await captureGeneric(win);
    cblog(`ErpCrawl: captured ${sections.length} section(s)`);
    return sections;
  } catch (e) { cblog(`ErpCrawl: ${e}`); return []; }
  finally { if (win && !win.isDestroyed()) win.destroy(); }
}

// MARK: - Page helpers

async function evalStr(win: BrowserWindow, js: string): Promise<string> {
  try { return String((await win.webContents.executeJavaScript(js, true)) ?? ""); } catch { return ""; }
}
async function evalBool(win: BrowserWindow, js: string): Promise<boolean> {
  try { return !!(await win.webContents.executeJavaScript(js, true)); } catch { return false; }
}
async function textOf(win: BrowserWindow, selector: string): Promise<string> {
  const js = `((document.querySelector(${JSON.stringify(selector)}) || document.body) || {}).innerText || ''`;
  return (await evalStr(win, js)).trim();
}
async function navigate(win: BrowserWindow, url: string): Promise<void> {
  await win.loadURL(url).catch(() => { /* empty/missing app still resolves to a short page */ });
}

/// Poll until the content region has real text (stabilized), or timeout.
async function waitForContent(win: BrowserWindow, selector: string, timeoutMs = 9000): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  let last = -1;
  while (Date.now() < deadline) {
    const len = (await textOf(win, selector)).length;
    if (len > 80 && len === last) return; // non-trivial and stable
    last = len;
    await delay(1000);
  }
}

/// The authenticated app shell is up (not a login page or a Cloudflare wall).
async function waitForApp(win: BrowserWindow, timeoutMs = 25000): Promise<boolean> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const url = await evalStr(win, "location.href");
    if (url.includes("/web/login") || url.toLowerCase().includes("accounts.google")) return false;
    if (await evalBool(win, "!!document.querySelector('.o_action_manager, .o_content, .o_main_navbar')")) return true;
    await delay(1000);
  }
  return false;
}

// MARK: - Odoo driver (proven in the Phase 0 spike)

/// Open each friendly Odoo app by its path and grab its content region. Odoo's
/// apps aren't plain links, so discovery by anchor fails; direct `/odoo/<app>`
/// navigation is what works. Apps the install lacks render an empty state and
/// fall below KEEP_MIN, so the fixed list self-filters to what the user has.
async function captureOdoo(win: BrowserWindow): Promise<string[]> {
  const sections: string[] = [];
  for (const slug of ODOO_APPS) {
    if (sections.length >= MAX_SECTIONS) break;
    await navigate(win, `${BASE}/odoo/${slug}`);
    await waitForContent(win, ".o_content");
    const text = await textOf(win, ".o_content");
    if (text.length > KEEP_MIN) sections.push(`## ${slug}\n${text}`);
  }
  return sections;
}

// MARK: - Generic fallback (any non-Odoo web ERP)

/// Best-effort: follow visible same-origin nav links and grab each page's body
/// text. Captures *something* for an ERP we have no driver for.
async function captureGeneric(win: BrowserWindow): Promise<string[]> {
  const json = await evalStr(win, `JSON.stringify([...document.querySelectorAll('nav a, aside a, [role=navigation] a, .menu a')]
    .map(a => ({label: (a.textContent||'').trim(), href: a.href||''}))
    .filter(x => x.href && x.href.startsWith(location.origin)))`);
  const links: { label: string; href: string }[] = [];
  try {
    const seen = new Set<string>();
    for (const it of JSON.parse(json) as { label: string; href: string }[]) {
      if (it.href && !seen.has(it.href) && !ErpContext.skipLink(it.href)) { seen.add(it.href); links.push(it); }
    }
  } catch { /* no links */ }
  const sections: string[] = [`## Home\n${await textOf(win, "body")}`];
  for (const l of links) {
    if (sections.length >= MAX_SECTIONS) break;
    await navigate(win, l.href);
    await waitForContent(win, "main");
    const text = await textOf(win, "main");
    if (text.length > KEEP_MIN) sections.push(`## ${l.label}\n${text}`);
  }
  return sections;
}
