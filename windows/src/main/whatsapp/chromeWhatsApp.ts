import { app, BrowserWindow, session } from "electron";
import * as fs from "fs";
import { resourcePath } from "../core/paths";
import { Settings } from "../core/settings";
import { cblog } from "../core/diag";
import { openUrl } from "../core/open";
import { CDPClient } from "./cdpClient";

// MARK: - Data types

export interface WAUnreadChat {
  name: string;
  unread: number;
  text: string;
  index: number | null;
  /// Detected from the sidebar row, WITHOUT opening the chat -- opening one
  /// marks it read and hides it from the user's phone, which is exactly the
  /// damage a group filter is supposed to prevent.
  isGroup: boolean;
  /// True when the row carries WhatsApp's own @-mention badge, or the preview
  /// text names the user with an "@".
  mentioned: boolean;
  /// Who sent the last message, when the row says so. Groups only -- a
  /// one-to-one row has no sender element, which is how `isGroup` is decided.
  sender: string;
  /// The last message, bidi control marks stripped.
  preview: string;
}

/// One bubble in the open chat. `at` is null when WhatsApp gave no timestamp
/// (a row continuing the one above) or it didn't parse.
export interface WAMessage {
  outgoing: boolean;
  at: Date | null;
  text: string;
}

/// A lightweight snapshot of a chat row's preview text (any chat, not just unread).
export interface WAChatPreview {
  name: string;
  preview: string;
}

/// One row from WhatsApp Web's Calls tab.
export interface WACall {
  name: string;
  info: string;      // e.g. "Missed voice call", "Outgoing video call"
  timeText: string;  // WhatsApp's own relative/absolute label, e.g. "10:42 am" or "Yesterday"
}

const WHATSAPP_URL = "https://web.whatsapp.com";
const PARTITION = "persist:whatsapp";

const sleep = (ms: number) => new Promise<void>(r => setTimeout(r, ms));

/// A JS string as a literal, quotes included.
const jsString = (s: string) => JSON.stringify(s);

/// Desktop Chrome on Windows, at the Chromium version Electron ships.
/// WhatsApp Web refuses browsers it doesn't recognise, and Electron's default
/// UA ("... Electron/x.y ...") is one of them. Chrome itself now reports only
/// the major version, so this matches a real Chrome byte for byte.
export function chromeUserAgent(chromeVersion: string = process.versions.chrome ?? "146.0.0.0"): string {
  const major = chromeVersion.split(".")[0] || "146";
  return `Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/${major}.0.0.0 Safari/537.36`;
}

function safeParse<T>(json: string | null, fallback: T): T {
  if (!json) return fallback;
  try { return JSON.parse(json) as T; } catch { return fallback; }
}

// MARK: - Nikxel's own WhatsApp window

/// The Mac app launched a SEPARATE Chrome with `--remote-debugging-port` and
/// an isolated `--user-data-dir`. On Windows WhatsApp Web runs in Nikxel's own
/// BrowserWindow instead, with its own persistent session partition — the
/// same isolation (the user's browser is never touched) without requiring a
/// Chromium browser to be installed. The user scans the QR once; the bot
/// drives the page via CDP entirely in the background, window hidden.
let win: BrowserWindow | null = null;
let cdp: CDPClient | null = null;
let quitting = false;
let quitHooked = false;

function createWindow(): BrowserWindow {
  const ua = chromeUserAgent();
  const ses = session.fromPartition(PARTITION);
  ses.setUserAgent(ua);
  // WhatsApp Web asks for notifications, mic and camera. The phone already
  // notifies, and nothing here records — say no rather than raise prompts
  // from a window the user usually can't see.
  ses.setPermissionRequestHandler((_wc, permission, callback) => {
    callback(permission === "clipboard-sanitized-write" || permission === "fullscreen");
  });
  ses.setPermissionCheckHandler((_wc, permission) =>
    permission === "clipboard-sanitized-write" || permission === "fullscreen");

  const icon = resourcePath("icon.png");
  const w = new BrowserWindow({
    width: 1200,
    height: 850,
    minWidth: 900,
    minHeight: 600,
    show: false,
    title: "WhatsApp — Nikxel",
    autoHideMenuBar: true,
    icon: fs.existsSync(icon) ? icon : undefined,
    webPreferences: {
      partition: PARTITION,
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true,
      // No Hunspell and dictionary download for a window the bot types into.
      spellcheck: false,
      // Keep timers and rendering alive while hidden, or the bot's polling
      // sees a frozen page. Also keeps the Page Visibility API "visible".
      backgroundThrottling: false,
    },
  });
  w.webContents.setUserAgent(ua);
  w.webContents.setBackgroundThrottling(false);

  // Links in chats open in the user's own browser, not in a stray Electron window.
  w.webContents.setWindowOpenHandler(({ url }) => {
    if (/^https?:/i.test(url)) openUrl(url);
    return { action: "deny" };
  });
  w.webContents.on("will-navigate", (e, url) => {
    if (!/^https:\/\/web\.whatsapp\.com/i.test(url)) { e.preventDefault(); if (/^https?:/i.test(url)) openUrl(url); }
  });

  // Closing hides: the session, the poller and the page stay alive while
  // Nikxel runs. Only a real quit destroys it.
  if (!quitHooked) {
    quitHooked = true;
    app.on("before-quit", () => { quitting = true; });
  }
  w.on("close", e => {
    if (quitting) return;
    e.preventDefault();
    w.hide();
  });
  w.on("closed", () => {
    if (win === w) { win = null; cdp = null; }
  });
  w.webContents.on("render-process-gone", (_e, details) => {
    cblog(`ChromeWhatsApp: renderer gone (${details.reason}) — reloading`);
    if (!w.isDestroyed()) w.loadURL(WHATSAPP_URL, { userAgent: ua }).catch(() => {});
  });

  cdp = new CDPClient(w.webContents, ua);
  // Attach before the first load so the client-hint override is in place
  // for WhatsApp's own browser check.
  cdp.attach();
  w.loadURL(WHATSAPP_URL, { userAgent: ua }).catch(e => cblog(`ChromeWhatsApp: load failed — ${e}`));
  cblog("ChromeWhatsApp: opened WhatsApp window");
  win = w;
  return w;
}

/// The window, created on demand. `force` creates it even when WhatsApp was
/// never connected — only for explicit user actions (setup, "show WhatsApp").
function ensureWindow(force: boolean): BrowserWindow | null {
  if (win && !win.isDestroyed()) return win;
  // Never connected WhatsApp: don't load WhatsApp Web on every poll. Setup
  // opens it itself; until then only use one already up.
  if (!force && !Settings.whatsappConnected) return null;
  try {
    return createWindow();
  } catch (e) {
    cblog(`ChromeWhatsApp: couldn't create window — ${e}`);
    return null;
  }
}

function ensureCDP(): CDPClient | null {
  if (!ensureWindow(false)) return null;
  return cdp;
}

function showWindow(w: BrowserWindow): void {
  if (w.isMinimized()) w.restore();
  w.show();
  w.focus();
}

// MARK: - WhatsApp Web bridge (CDP-backed)

/// All WhatsApp Web interaction goes through one CDP connection to the
/// WhatsApp window. No focus stealing; no clipboard hijack; no screen-coord math.
export const ChromeWhatsApp = {
  /// The window, if it has been created. For wiring (e.g. a tray item).
  get window(): BrowserWindow | null { return win && !win.isDestroyed() ? win : null; },

  /// Shows the window at web.whatsapp.com for the QR scan. Resolves once the
  /// page has loaded (or failed to — the window stays up either way).
  async openForLogin(): Promise<void> {
    const w = ensureWindow(true);
    if (!w) return;
    showWindow(w);
    const url = w.webContents.getURL();
    if (!url.startsWith(WHATSAPP_URL)) {
      await w.loadURL(WHATSAPP_URL, { userAgent: chromeUserAgent() }).catch(e => cblog(`ChromeWhatsApp: load failed — ${e}`));
    } else if (w.webContents.isLoading()) {
      await new Promise<void>(resolve => {
        const done = () => resolve();
        w.webContents.once("did-finish-load", done);
        w.webContents.once("did-fail-load", done);
      });
    }
  },

  /// Hides the window without closing the session.
  hide(): void { win?.hide(); },

  // MARK: - High-level API

  /// True once WhatsApp Web has a logged-in chat list visible (as opposed
  /// to showing the QR code or still loading). Used by the onboarding
  /// wizard to poll for "scan complete" without the user clicking anything.
  async isLoggedIn(): Promise<boolean> {
    const c = ensureCDP();
    if (!c) return false;
    const js = `
    (function(){
        if (document.querySelector('canvas[aria-label], div[data-ref]')) return 'false';
        return !!document.querySelector('#pane-side, [aria-label="Chat list"]') ? 'true' : 'false';
    })()
    `;
    return (await c.eval(js)) === "true";
  },

  /// WhatsApp Web's JS heap, in MB; 0 when it can't be read.
  async heapMB(): Promise<number> {
    const c = ensureCDP();
    if (!c) return 0;
    return parseInt((await c.eval("String(Math.round(((performance.memory || {}).usedJSHeapSize || 0) / 1e6))")) ?? "", 10) || 0;
  },

  /// Reload WhatsApp Web and wait until its chat list is back (or 60s).
  async reloadPage(): Promise<boolean> {
    const c = ensureCDP();
    if (!c) return false;
    await c.eval("setTimeout(function(){ location.reload(); }, 0), 'ok'");
    await sleep(3000);
    const deadline = Date.now() + 60_000;
    while (Date.now() < deadline) {
      if (await ChromeWhatsApp.isLoggedIn()) return true;
      await sleep(1000);
    }
    return false;
  },

  /// Get all unread chats from the sidebar.
  ///
  /// Also reports whether each row is a group and whether the user was
  /// @-mentioned in it, so `ChatbotEngine` can drop group chatter before
  /// clicking anything.
  ///
  /// The group test reads WhatsApp's own markup rather than guessing from
  /// text. Inside `[data-testid="last-msg-status"]` a group row looks like:
  ///
  ///     <span title="Happy Diwali" data-testid="last-msg-status">
  ///       <div><div><span dir="auto">PM Prince</span></div></div>
  ///       <span>:&nbsp;</span>
  ///       <span dir="ltr">Happy Diwali</span>
  ///
  /// A one-to-one row has no sender element and no ":&nbsp;" separator -- it
  /// goes straight to the message, or to a `chat-msg-symbol` for media. That
  /// separator span is therefore the signal, and the sender name next to it
  /// comes out for free.
  ///
  /// An earlier version read the sender out of the row's `title` attribute.
  /// It never worked: the title holds the message only, so every group in a
  /// real chat list came back as a one-to-one.
  async unreadChats(): Promise<WAUnreadChat[]> {
    const c = ensureCDP();
    if (!c) return [];
    const own = Settings.waOwnName;
    const escapedSelf = jsString(own);
    // Mentions are written "@Firstname" far more often than "@Full Name",
    // so match on the first word too.
    const escapedFirst = jsString(own.split(" ").filter(Boolean)[0] ?? own);
    const js = `
    (function(){
        var SELF_NAME = ${escapedSelf};
        var SELF_FIRST = ${escapedFirst};
        // WhatsApp wraps every title in bidi isolates; a regex anchored at
        // ^ would otherwise be looking at U+202A.
        var BIDI = /[\\u202A-\\u202E\\u200E\\u200F\\u2066-\\u2069]/g;
        var result = [];
        var labels = document.querySelectorAll('#pane-side span[aria-label]');   // the chat list only
        for (var i = 0; i < labels.length; i++) {
            var ar = labels[i].getAttribute('aria-label') || '';
            var m = ar.match(/(\\d+)\\s*unread/i);
            if (!m) continue;
            var row = labels[i].closest('[role="row"]');
            if (!row) continue;

            // The row has TWO span[title]: the chat name and the message
            // preview. Pick the name by excluding the preview rather than
            // by document order.
            var nameEl = row.querySelector('span[title]:not([data-testid="last-msg-status"])');
            var name = nameEl ? (nameEl.getAttribute('title') || '').replace(BIDI, '').trim() : '';
            if (!name) {
                var dirEl = row.querySelector('span[dir="auto"]');
                name = dirEl ? dirEl.textContent.trim() : '';
            }
            if (!name) continue;
            if (name === 'Message yourself' || name === SELF_NAME) continue;

            var status = row.querySelector('[data-testid="last-msg-status"]');
            var preview = status ? (status.getAttribute('title') || '').replace(BIDI, '').trim() : '';

            var isGroup = false, sender = '';
            if (status) {
                for (var k = 0; k < status.children.length; k++) {
                    // trim() drops the &nbsp;, leaving a bare colon.
                    if ((status.children[k].textContent || '').trim() === ':') {
                        isGroup = true;
                        break;
                    }
                }
                if (isGroup) {
                    var auto = status.querySelector('span[dir="auto"]');
                    if (auto) sender = (auto.textContent || '').replace(BIDI, '').trim();
                }
            }
            if (!isGroup) {
                isGroup = !!row.querySelector('[data-icon="default-group"], [data-icon="group"]');
            }

            var mentioned = !!row.querySelector('[data-icon*="mention" i], [aria-label*="mention" i]')
                || /mention/i.test(ar);
            if (!mentioned && SELF_FIRST) {
                mentioned = preview.indexOf('@' + SELF_FIRST) >= 0
                    || preview.indexOf('@' + SELF_NAME) >= 0;
            }

            result.push({
                name: name,
                unread: parseInt(m[1]),
                text: row.textContent.trim().substring(0, 300),
                index: i,
                isGroup: isGroup,
                mentioned: mentioned,
                sender: sender,
                preview: preview
            });
        }
        return JSON.stringify(result.slice(0, 50));
    })()
    `;
    const rows = safeParse<any[]>(await c.eval(js), []);
    if (!Array.isArray(rows)) return [];
    return rows
      .filter(r => r && typeof r.name === "string" && typeof r.unread === "number")
      .map(r => ({
        name: r.name,
        unread: r.unread,
        text: String(r.text ?? ""),
        index: typeof r.index === "number" ? r.index : null,
        isGroup: !!r.isGroup,
        mentioned: !!r.mentioned,
        sender: String(r.sender ?? ""),
        preview: String(r.preview ?? ""),
      }));
  },

  /// Open the chat for `name`: finds the row's centre (viewport coords) so CDP
  /// `Input.dispatchMouseEvent` can target it without any screen-coord math.
  async clickChat(name: string): Promise<boolean> {
    const c = ensureCDP();
    if (!c) return false;
    // Scroll the row into view (the chat list is virtualized) then
    // return its center point in viewport coords. CDP dispatches the
    // mouse event at viewport coords directly.
    const js = `
    (function(){
        var target = ${jsString(name)};
        var rows = document.querySelectorAll('[role="row"]');
        for (var i = 0; i < rows.length; i++) {
            var titleEl = rows[i].querySelector('span[title]');
            var n = titleEl ? (titleEl.getAttribute('title') || '').trim() : '';
            if (!n) {
                var dirEl = rows[i].querySelector('span[dir="auto"]');
                n = dirEl ? dirEl.textContent.trim() : '';
            }
            if (n === target) {
                var cell = rows[i].querySelector('[role="gridcell"]') || rows[i];
                cell.scrollIntoView({block: 'center', behavior: 'instant'});
                var r = cell.getBoundingClientRect();
                return JSON.stringify({x: r.x + r.width/2, y: r.y + r.height/2});
            }
        }
        return '';
    })()
    `;
    const pt = safeParse<{ x?: number; y?: number } | null>(await c.eval(js), null);
    if (!pt || typeof pt.x !== "number" || typeof pt.y !== "number") {
      cblog(`CDP: clickChat row not found for '${name}'`);
      return false;
    }
    // Brief wait for scroll to settle before clicking.
    await sleep(150);
    await c.clickAt(pt.x, pt.y);
    await sleep(600);

    // Windows only: a window that has never been shown can miss a
    // coordinate click (nothing composited to hit-test against). If the pane
    // didn't switch, press the row from inside the page instead. React
    // handles these the same way; only the isTrusted flag differs.
    const header = await ChromeWhatsApp.conversationHeader();
    if (header !== null && !ChromeWhatsApp.headerMatches(header, name)) {
      const pressJS = `
      (function(){
          var target = ${jsString(name)};
          var rows = document.querySelectorAll('[role="row"]');
          for (var i = 0; i < rows.length; i++) {
              var titleEl = rows[i].querySelector('span[title]');
              var n = titleEl ? (titleEl.getAttribute('title') || '').trim() : '';
              if (!n) {
                  var dirEl = rows[i].querySelector('span[dir="auto"]');
                  n = dirEl ? dirEl.textContent.trim() : '';
              }
              if (n === target) {
                  var cell = rows[i].querySelector('[role="gridcell"]') || rows[i];
                  ['pointerdown', 'mousedown', 'pointerup', 'mouseup', 'click'].forEach(function(t){
                      var E = t.indexOf('pointer') === 0 ? PointerEvent : MouseEvent;
                      cell.dispatchEvent(new E(t, {bubbles: true, cancelable: true, view: window, button: 0}));
                  });
                  return 'ok';
              }
          }
          return '';
      })()
      `;
      if ((await c.eval(pressJS)) === "ok") {
        cblog(`CDP: clickChat '${name}' — coordinate click missed, pressed the row in-page`);
        await sleep(600);
      }
    }
    return true;
  },

  /// Whether the open conversation's header names `name`. No header at all
  /// is the caller's call. `contains` as well as the prefix tests: WhatsApp
  /// qualifies a group's label with a leading word ("group Warrior Tennis"),
  /// and that word is localised, so it cannot all be stripped by name.
  /// Containment covers whatever the qualifier turns out to be while still
  /// catching a genuinely wrong chat.
  headerMatches(header: string, name: string): boolean {
    const a = header.toLowerCase().trim();
    const b = name.toLowerCase().trim();
    return a === b || a.startsWith(b) || b.startsWith(a) || a.includes(b);
  },

  /// Name and group-ness of the conversation currently open in the right
  /// pane, read from the message box's own aria-label.
  ///
  /// WhatsApp writes "Type a message to Kirti Forklyft" for a one-to-one and
  /// "Type a message to group Warrior Tennis" for a group. That one word is
  /// the only authoritative group signal in the page -- both heuristics tried
  /// before it (a `default-group` icon, counting distinct senders in the
  /// loaded history) returned false on real groups.
  async openConversation(): Promise<{ name: string; isGroup: boolean } | null> {
    const c = ensureCDP();
    if (!c) return null;
    const js = `
    (function(){
        var input = document.querySelector('[contenteditable="true"][aria-label]');
        if (input) {
            var ar = input.getAttribute('aria-label') || '';
            var m = ar.match(/^Type a message to (.+)$/);
            if (m) return m[1].trim();
        }
        var headers = document.querySelectorAll('header');
        for (var i = 0; i < headers.length; i++) {
            if (headers[i].querySelector('[title="Profile details"]')) {
                var s = headers[i].querySelector('span');
                if (s) return s.textContent.trim();
            }
        }
        return '';
    })()
    `;
    const label = await c.eval(js);
    if (!label) return null;
    return ChromeWhatsApp.parseConversationLabel(label);
  },

  /// Split out from `openConversation` so the qualifier handling can be
  /// checked against the exact strings WhatsApp was observed to emit --
  /// see checks/waBot.test.ts.
  parseConversationLabel(label: string): { name: string; isGroup: boolean } {
    const trimmed = label.trim();
    if (trimmed.toLowerCase().startsWith("group ")) {
      return { name: trimmed.slice("group ".length).trim(), isGroup: true };
    }
    return { name: trimmed, isGroup: false };
  },

  /// Just the name, with any "group " qualifier removed.
  ///
  /// Leaving that word in broke the engine's "am I in the right chat" check
  /// for every group: "group Warrior Tennis" never matched "Warrior Tennis",
  /// so a tagged group message the user had explicitly allowed was aborted
  /// instead of answered.
  async conversationHeader(): Promise<string | null> {
    return (await ChromeWhatsApp.openConversation())?.name ?? null;
  },

  /// Whether the open conversation is a group.
  ///
  /// ponytail: the "group " qualifier is English, so this reads as a
  /// one-to-one under a non-English WhatsApp UI. The sidebar check in
  /// `unreadChats` is language-independent and is the one that actually
  /// gates replies; this is the backstop. Upgrade path is matching the label
  /// against the clicked chat name and treating any leading extra word as
  /// the qualifier, whatever language it is in.
  async openChatIsGroup(): Promise<boolean> {
    return (await ChromeWhatsApp.openConversation())?.isGroup ?? false;
  },

  /// Read the last `count` INCOMING messages from the open conversation.
  ///
  /// Direction is resolved per row, in this order:
  ///
  /// 1. `data-pre-plain-text` -- `"[12:34 pm, 18/06/2026] Sender Name: "`.
  ///    Names the sender outright. Present for text from a resolvable sender,
  ///    which covers saved contacts and group members.
  /// 2. `tail-in` / `tail-out`, the SVG title on a bubble's tail.
  /// 3. Inherited from the row above.
  ///
  /// Step 3 is not a nicety. A tail marks only the FIRST bubble of a run, so
  /// in any run of two or more the NEWEST message carries neither signal --
  /// and that is exactly the message the bot is answering. Measured on a real
  /// group, the latest message was dropped without it. Hence the walk is
  /// oldest-to-newest, carrying direction forward, rather than newest-first.
  ///
  /// A row is only taken if it has `.selectable-text`. Using the row's own
  /// textContent instead pulled in the SVG title of every icon on the bubble:
  /// a voice note read as "ic-downloadic-headphones-filledic-bookmark-filled
  /// 9:27 pm". Stickers, images and voice notes therefore yield nothing,
  /// which is right -- there is no text in them to reply to.
  async readMessages(count = 6, userOwnName: string = Settings.waOwnName): Promise<string[]> {
    const thread = await ChromeWhatsApp.readThread(userOwnName);
    return thread.filter(m => !m.outgoing).map(m => m.text).slice(-count);
  },

  /// Every rendered bubble in the open chat, both directions, oldest first.
  async readThread(userOwnName: string = Settings.waOwnName): Promise<WAMessage[]> {
    const c = ensureCDP();
    if (!c) return [];
    const js = `
    (function(){
        var SELF = ${jsString(userOwnName)};
        var main = document.querySelector('#main');
        if (!main) return '[]';
        var rows = main.querySelectorAll('[role="row"]');
        var out = [];
        var carried = null;   // direction of the last row we could place
        for (var i = 0; i < rows.length; i++) {
            var row = rows[i];
            var rowText = row.textContent || '';
            var dir = null;

            var pre = row.querySelector('[data-pre-plain-text]');
            var ts = '';
            if (pre) {
                var m = (pre.getAttribute('data-pre-plain-text') || '')
                    .match(/^\\[([^\\]]+)\\]\\s*(.+?):\\s*$/);
                if (m) {
                    ts = m[1];
                    var sender = m[2].trim();
                    dir = (sender === SELF || sender.indexOf(SELF) === 0) ? 'out' : 'in';
                }
            }
            if (dir === null) {
                if (/tail-out/.test(rowText)) dir = 'out';
                else if (/tail-in/.test(rowText)) dir = 'in';
            }
            if (dir === null) dir = carried;   // same run as the row above
            if (dir !== null) carried = dir;
            if (dir === null) continue;

            var sel = row.querySelector('.selectable-text');
            if (!sel) continue;
            var txt = (sel.textContent || '')
                .replace(/\\s*\\d{1,2}:\\d{2}\\s*[ap]m\\s*$/i, '')
                .trim();
            if (txt) out.push([dir, ts, txt]);
        }
        return JSON.stringify(out);
    })()
    `;
    const rows = safeParse<unknown[]>(await c.eval(js), []);
    if (!Array.isArray(rows)) return [];
    const out: WAMessage[] = [];
    for (const r of rows) {
      if (!Array.isArray(r) || r.length !== 3) continue;
      out.push({ outgoing: r[0] === "out", at: ChromeWhatsApp.parseStamp(String(r[1])), text: String(r[2]) });
    }
    return out;
  },

  /// WhatsApp's `data-pre-plain-text` stamp, e.g. "2:46 pm, 10/11/2026".
  /// ponytail: day-first dates and 12h/24h clocks only (what an Indian-locale
  /// WhatsApp Web writes); a US-locale M/d stamp will misparse or return null,
  /// which only costs the idle cutoff for that message.
  parseStamp(s: string): Date | null {
    const t = s.trim();
    // "h:mm a, d/M/yyyy" then "HH:mm, d/M/yyyy".
    const m12 = t.match(/^(\d{1,2}):(\d{2})\s*([ap]m),\s*(\d{1,2})\/(\d{1,2})\/(\d{4})$/i);
    const m24 = m12 ? null : t.match(/^(\d{1,2}):(\d{2}),\s*(\d{1,2})\/(\d{1,2})\/(\d{4})$/);
    let h: number, min: number, d: number, mo: number, y: number;
    if (m12) {
      h = +m12[1]; min = +m12[2]; d = +m12[4]; mo = +m12[5]; y = +m12[6];
      if (h < 1 || h > 12) return null;
      const pm = m12[3].toLowerCase() === "pm";
      h = (h % 12) + (pm ? 12 : 0);
    } else if (m24) {
      h = +m24[1]; min = +m24[2]; d = +m24[3]; mo = +m24[4]; y = +m24[5];
      if (h > 23) return null;
    } else {
      return null;
    }
    if (min > 59) return null;
    const date = new Date(y, mo - 1, d, h, min, 0, 0);
    // Not lenient: 31/2 is an error, not 3 March.
    if (date.getFullYear() !== y || date.getMonth() !== mo - 1 || date.getDate() !== d) return null;
    return date;
  },

  /// Wait until the open conversation has actually rendered its messages.
  ///
  /// The message pane is virtualised and populates after the click settles;
  /// querying too early returns zero rows, which `readMessages` cannot tell
  /// apart from "nothing to read". A real chat measured zero rows at the 0.6s
  /// the engine used to allow.
  async waitForMessages(timeoutSec = 4): Promise<boolean> {
    const c = ensureCDP();
    if (!c) return false;
    const deadline = Date.now() + timeoutSec * 1000;
    while (Date.now() < deadline) {
      const n = await c.eval(`(function(){var m=document.querySelector('#main');return m ? String(m.querySelectorAll('[role="row"]').length) : '0';})()`);
      const count = n === null ? NaN : parseInt(n, 10);
      if (count > 0) return true;
      await sleep(300);
    }
    return false;
  },

  /// Snapshot of every visible chat row's preview text, NOT just unread
  /// ones — used by `WhatsAppActivityLogger` to build a running picture of
  /// the day's chats (including ones already read on the phone) for the
  /// daily summary.
  async allChatsPreview(limit = 60): Promise<WAChatPreview[]> {
    const c = ensureCDP();
    if (!c) return [];
    const js = `
    (function(){
        // Only the sidebar: [role="row"] page-wide also matched the
        // open chat's message bubbles, which logged "1:36 pm" as a chat
        // name and SVG icon names as text. Name and preview come from the
        // same elements unreadChats reads; group rows keep their sender.
        var BIDI = /[\\u202A-\\u202E\\u200E\\u200F\\u2066-\\u2069]/g;
        var result = [];
        var rows = document.querySelectorAll('#pane-side [role="row"]');
        for (var i = 0; i < rows.length && result.length < ${Math.floor(limit)}; i++) {
            var status = rows[i].querySelector('[data-testid="last-msg-status"]');
            var nameEl = rows[i].querySelector('span[title]:not([data-testid="last-msg-status"])');
            var name = nameEl ? (nameEl.getAttribute('title') || '').replace(BIDI, '').trim() : '';
            var preview = status ? (status.getAttribute('title') || '').replace(BIDI, '').trim() : '';
            if (!name || !preview || name === 'Message yourself') continue;
            var sender = '';
            for (var k = 0; k < status.children.length; k++) {
                if ((status.children[k].textContent || '').trim() === ':') {
                    var auto = status.querySelector('span[dir="auto"]');
                    if (auto) sender = (auto.textContent || '').replace(BIDI, '').trim();
                    break;
                }
            }
            result.push({name: name, preview: (sender ? sender + ': ' : '') + preview.substring(0, 300)});
        }
        return JSON.stringify(result);
    })()
    `;
    const rows = safeParse<any[]>(await c.eval(js), []);
    if (!Array.isArray(rows)) return [];
    return rows
      .filter(r => r && typeof r.name === "string")
      .map(r => ({ name: r.name, preview: String(r.preview ?? "") }));
  },

  /// Switch the left sidebar from Chats to the Calls tab. WhatsApp Web's
  /// nav rail exposes it as a button labeled "Calls".
  async openCallsTab(): Promise<boolean> {
    const c = ensureCDP();
    if (!c) return false;
    const js = `
    (function(){
        var btn = document.querySelector('button[aria-label="Calls"]')
            || document.querySelector('[aria-label="Calls"]');
        if (!btn) return 'not_found';
        btn.click();
        return 'ok';
    })()
    `;
    const result = (await c.eval(js)) ?? "";
    if (result !== "ok") {
      cblog(`CDP: callLog — Calls tab button not found (${result}); WhatsApp Web DOM may have changed`);
      return false;
    }
    await sleep(1000);   // the list measured ~1s to render
    return true;
  },

  /// Switch back to the Chats tab — called after reading the call log so
  /// `ChatbotEngine`'s unread-chat polling (which assumes the Chats list
  /// is on screen) isn't left looking at the Calls tab.
  async openChatsTab(): Promise<boolean> {
    const c = ensureCDP();
    if (!c) return false;
    const js = `
    (function(){
        var btn = document.querySelector('button[aria-label="Chats"]')
            || document.querySelector('[aria-label="Chats"]');
        if (!btn) return 'not_found';
        btn.click();
        return 'ok';
    })()
    `;
    return ((await c.eval(js)) ?? "") === "ok";
  },

  /// Read the call log (Calls tab). WhatsApp Web exposes no call
  /// audio/transcript via the DOM — only metadata: caller, call type
  /// (missed/incoming/outgoing, voice/video), and WhatsApp's own time
  /// label. Best-effort selectors; WhatsApp Web's DOM changes over time,
  /// so an empty result here doesn't necessarily mean there were no calls.
  async callLog(limit = 30): Promise<WACall[]> {
    if (!(await ChromeWhatsApp.openCallsTab())) return [];
    const c = ensureCDP();
    if (!c) return [];
    const js = `
    (function(){
        // A call row's visible text is [name, time, "Incoming"/"Outgoing"/
        // "Missed" (+ " (2)")]; voice vs video is only in the icon's SVG
        // title, which is why text inside <svg> is skipped and read apart.
        // ponytail: English labels only; a localised WhatsApp logs no calls.
        var result = [];
        var rows = document.querySelectorAll('#pane-side [role="row"]');
        for (var i = 0; i < rows.length && result.length < ${Math.floor(limit)}; i++) {
            var w = document.createTreeWalker(rows[i], NodeFilter.SHOW_TEXT), n, t = [];
            while ((n = w.nextNode())) {
                var s = n.parentElement.closest('svg') ? '' : n.textContent.trim();
                if (s) t.push(s);
            }
            if (t.length < 3 || !/^(missed|incoming|outgoing)/i.test(t[t.length - 1])) continue;
            var icons = Array.from(rows[i].querySelectorAll('svg title')).map(function(x){ return x.textContent; }).join(' ');
            result.push({name: t[0], info: t[t.length - 1] + (/video/i.test(icons) ? ' video call' : ' voice call'), timeText: t[1]});
        }
        return JSON.stringify(result);
    })()
    `;
    const rows = safeParse<any[]>(await c.eval(js), []);
    if (!Array.isArray(rows)) return [];
    return rows
      .filter(r => r && typeof r.name === "string")
      .map(r => ({ name: r.name, info: String(r.info ?? ""), timeText: String(r.timeText ?? "") }));
  },

  /// Type a reply into the open conversation and leave it there unsent.
  /// WhatsApp keeps a per-chat draft, so the bot can draft into several chats
  /// in a row and each one holds its own text until the user looks.
  draftMessage(text: string): Promise<boolean> {
    return ChromeWhatsApp.sendMessage(text, false);
  },

  /// Send a reply to the open conversation. Returns false if the chat has
  /// no reply input (read-only business/broadcast/channel chats expose no
  /// contenteditable footer — bot must skip them, not retry).
  ///
  /// `send: false` stops after typing, which is what draft-only mode wants.
  async sendMessage(text: string, send = true): Promise<boolean> {
    const c = ensureCDP();
    if (!c) return false;
    const focusJS = `
    (function(){
        var input = document.querySelector('[contenteditable="true"][data-tab="10"]')
            || document.querySelector('footer [contenteditable="true"]')
            || document.querySelector('[contenteditable="true"]');
        if (!input) return 'no_input';
        input.focus();
        return 'ok';
    })()
    `;
    const focusResult = (await c.eval(focusJS)) ?? "";
    if (focusResult === "no_input") {
      cblog("CDP: sendMessage skipped — no reply input (read-only chat)");
      return false;
    }
    if (focusResult !== "ok") {
      cblog(`CDP: sendMessage focus failed (got '${focusResult}')`);
      return false;
    }
    await sleep(100);
    await c.insertText(text);
    await sleep(150);
    if (!send) {
      cblog("CDP: drafted (not sent)");
      return true;
    }
    await c.pressEnter();
    return true;
  },

  /// Bring the WhatsApp window to the front, so the user can look at a draft
  /// the bot left in a chat. Not used by the reply path itself — that runs
  /// entirely over CDP and never needs the window shown.
  activate(): void {
    const w = ensureWindow(true);
    if (w) showWindow(w);
  },
};
