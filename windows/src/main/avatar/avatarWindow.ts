import { BrowserWindow, ipcMain, screen, IpcMainEvent, Rectangle } from "electron";
import * as fs from "fs";
import { StateMachine, NikxelState } from "../core/stateMachine";
import { ui, AvatarSurface, CardOptions, CardKind } from "../core/ui";
import { bus } from "../core/bus";
import { Settings, Sprites } from "../core/settings";
import { preloadPath, rendererPath, resourcePath, isWin } from "../core/paths";
import { diag } from "../core/diag";
import { clickDecision } from "../system/chatContext";

/// Port of NikxelWindowController.swift (the window, drag, clicks) plus the
/// main-process half of NikxelView.swift. Drawing and hit testing live in the
/// renderer (src/renderer/avatar.ts); this side owns the BrowserWindow, moves
/// it while dragging, keeps the card callbacks, and tells the renderer what to
/// show.

/// The window is taller than it is wide so notification cards have room
/// above the avatar's head -- or, with `bubblesBelow`, the same room under
/// its feet. The avatar sits in the middle.
/// Wider than any card so a card can slide sideways to stay on screen when
/// the avatar is at an edge. The empty part lets clicks through.
export const VIEW_WIDTH = 640;
export const VIEW_HEIGHT = 700;
export const AVATAR_BOTTOM_INSET = 350;
/// Avatar centre in window coordinates, y-down. The Swift view is y-up with
/// the centre 350 pt above the bottom; 700 - 350 puts it at the same spot.
type AvatarWindow = AvatarSurface & {
  avatarRect(): Electron.Rectangle;
  window: BrowserWindow; recordKeystroke(): void; globalMouseDown(): void; globalMouseUp(): void;
};

const AVATAR_CENTER = { x: VIEW_WIDTH / 2, y: VIEW_HEIGHT - AVATAR_BOTTOM_INSET };

/// Card as sent to the renderer: the callbacks stay here, keyed by id.
export interface CardWire {
  id: number;
  icon: string | null;
  title: string;
  lines: string[];
  bulleted: boolean;
  kind: CardKind;
  /// Seconds; null = stays until clicked (Infinity doesn't need to cross IPC).
  lifetime: number | null;
  buttons: string[];
}

interface Geom { waLeft: number; waRight: number }

/// main → renderer, on "avatar:msg".
export type ToRenderer =
  | { type: "init"; state: NikxelState; avatarSize: number; bubblesBelow: boolean; geom: Geom;
      sprite: Uint8Array | null; fallback: Uint8Array | null; fontBold: Uint8Array | null; fontMedium: Uint8Array | null }
  | { type: "sprites"; sprite: Uint8Array | null; fallback: Uint8Array | null }
  | { type: "state"; state: NikxelState }
  | { type: "size"; avatarSize: number }
  | { type: "cursor"; x: number; y: number }
  | { type: "geom"; geom: Geom }
  | { type: "bubblesBelow"; on: boolean }
  | { type: "dragVelocity"; vx: number; vy: number }
  | { type: "springBack" }
  | { type: "puff" }
  | { type: "key" }
  | { type: "card"; card: CardWire }
  | { type: "dismissCard" }
  | { type: "pushReminder"; id: string; title: string }
  | { type: "dismissReminder"; id: string }
  | { type: "reminderText"; text: string | null }
  | { type: "recording"; startedAt: number | null }
  | { type: "texter"; name: string | null };

/// renderer → main, on "avatar:event".
export type FromRenderer =
  | { type: "ready" }
  | { type: "loaded" }
  | { type: "interactive"; on: boolean }
  | { type: "dragStart" }
  | { type: "mouseUp" }
  | { type: "doubleClick" }
  | { type: "click"; moved: number; second: boolean }
  | { type: "cardTap"; id: number }
  | { type: "cardButton"; id: number; index: number }
  | { type: "cardGone"; id: number }
  | { type: "reminderTap"; id: string }
  /// Any left press the window received, sent before whatever it turns into.
  | { type: "press" };

async function readOrNull(file: string): Promise<Uint8Array | null> {
  try { return await fs.promises.readFile(file); }
  catch (e) { diag("avatar", `couldn't read ${file}: ${e}`); return null; }
}

async function loadSprites(): Promise<{ sprite: Uint8Array | null; fallback: Uint8Array | null }> {
  const [sprite, fallback] = await Promise.all([
    readOrNull(Sprites.activePath()),
    readOrNull(resourcePath("nikxel_avatar.png")),
  ]);
  return { sprite, fallback };
}

export function createAvatarWindow(
  sm: StateMachine,
  handlers: { onDoubleClick: () => void; onClick: (avatar: Rectangle) => void; onDrag?: () => void },
): AvatarWindow {
  // Starts with the avatar centred on the primary display.
  const primary = screen.getPrimaryDisplay().bounds;
  const start = {
    x: Math.round(primary.x + primary.width / 2 - AVATAR_CENTER.x),
    y: Math.round(primary.y + primary.height / 2 - AVATAR_CENTER.y),
  };

  const win = new BrowserWindow({
    x: start.x, y: start.y, width: VIEW_WIDTH, height: VIEW_HEIGHT,
    show: false,
    frame: false,
    transparent: true,
    backgroundColor: "#00000000",
    hasShadow: false,
    resizable: false,
    minimizable: false,
    maximizable: false,
    fullscreenable: false,
    skipTaskbar: true,
    alwaysOnTop: true,
    // Never takes keyboard focus: clicking Nikxel mustn't pull focus out of
    // the editor the user is typing in. Mouse input still arrives.
    focusable: false,
    // WS_EX_TOOLWINDOW: also keeps it out of Alt+Tab (.ignoresCycle).
    ...(isWin ? { type: "toolbar" } : {}),
    title: "Nikxel",
    webPreferences: {
      preload: preloadPath("avatar"),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true,
      // The animation runs on requestAnimationFrame; never let Chromium slow
      // it down because the window isn't focused (it never is).
      backgroundThrottling: false,
      spellcheck: false,
    },
  });
  win.setAlwaysOnTop(true, "screen-saver");
  win.setVisibleOnAllWorkspaces(true, { visibleOnFullScreen: true });
  // Transparent padding lets clicks through until the renderer says the
  // pointer is over Nikxel, a card or a bubble.
  win.setIgnoreMouseEvents(true, { forward: true });
  win.setMenu(null);

  // ---- Renderer link ---------------------------------------------------

  /// Messages sent before the renderer has its init are held and flushed after.
  let initSent = false;
  let loaded = false;
  let queue: ToRenderer[] = [];
  const sendNow = (m: ToRenderer) => {
    if (!win.isDestroyed()) win.webContents.send("avatar:msg", m);
  };
  const send = (m: ToRenderer) => {
    if (initSent) sendNow(m); else queue.push(m);
  };

  // ---- Cached view state -------------------------------------------------

  /// Sprite size: 156 px times the user's Avatar Size. Cached, not read from
  /// settings per drag tick -- settings is a file.
  let charSize = 156 * Settings.avatarSize;
  const halfChar = () => charSize / 2;
  let bubblesBelow = false;
  let wantVisible = true;
  let interactive = false;
  /// Click-through follows what the renderer last said, applied again on every
  /// report, show and display change rather than only when it flips: a style
  /// Windows dropped (a hide/show, a DPI or monitor change) would otherwise
  /// stay dropped, and Nikxel kept moving but took no clicks.
  const applyInteractive = () => {
    if (!win.isDestroyed()) win.setIgnoreMouseEvents(!interactive, { forward: true });
  };
  /// For the global-hook fallback and the Copy Logs line.
  let lastPressAt = 0;
  const stats = { reports: 0, presses: 0, missed: 0 };
  let hookPress: { at: number; x: number; y: number } | null = null;
  let pendingClick: ReturnType<typeof setTimeout> | undefined;
  /// Last values of the persistent overlays, replayed if the renderer reloads.
  const sticky: { reminderText: string | null; recording: number | null; texter: string | null } =
    { reminderText: null, recording: null, texter: null };

  const setBubblesBelow = (on: boolean) => {
    if (on === bubblesBelow) return;
    bubblesBelow = on;
    send({ type: "bubblesBelow", on });
  };

  const geomFor = (b: Rectangle): Geom => {
    const wa = screen.getDisplayMatching(b).workArea;
    return { waLeft: wa.x - b.x, waRight: wa.x + wa.width - b.x };
  };
  let lastGeom = "";
  const pushGeom = () => {
    if (win.isDestroyed()) return;
    const g = geomFor(win.getBounds());
    const key = `${g.waLeft},${g.waRight}`;
    if (key === lastGeom) return;
    lastGeom = key;
    send({ type: "geom", geom: g });
  };

  // ---- Cards -------------------------------------------------------------

  // One card at a time, newest replacing the last. The things that raise one
  // -- a summary finishing, a failure, the 10pm digest -- can't overlap in
  // practice, and a stack would cost layout and hit-testing for a case that
  // doesn't happen.
  let cardSeq = 0;
  let current: { id: number; card: CardOptions } | null = null;

  const runSafely = (what: string, fn: (() => void) | undefined) => {
    if (!fn) return;
    try { fn(); } catch (e) { diag("avatar", `${what} threw: ${e instanceof Error ? e.stack : e}`); }
  };

  // ---- Drag (NikxelWindow.mouseDown/mouseDragged/mouseUp) ----------------

  let dragging = false;
  let dragOffset = { x: 0, y: 0 };
  let prevDragPos = { x: 0, y: 0 };
  let prevDragTime = 0;
  let dragTimer: NodeJS.Timeout | null = null;

  const dragTick = () => {
    if (!dragging || win.isDestroyed()) return;
    const loc = screen.getCursorScreenPoint();
    const now = performance.now() / 1000;

    // Velocity tracking for inertia wiggle
    const dt = now - prevDragTime;
    if (dt > 0.001) {
      send({ type: "dragVelocity", vx: (loc.x - prevDragPos.x) / dt, vy: (loc.y - prevDragPos.y) / dt });
    }
    prevDragPos = loc;
    prevDragTime = now;

    let x = loc.x - dragOffset.x;
    let y = loc.y - dragOffset.y;
    // Clamp the avatar, not the window: the window has 90+ px of empty
    // padding round the sprite, which kept Nikxel well off the edges.
    // Sides by half the sprite (its 64 px frame is mostly transparent at
    // the sides), feet on the taskbar, head under the top of the work area.
    // Windows is y-down, and the work area leaves the taskbar out wherever
    // it's docked.
    const a = AVATAR_CENTER, h = halfChar();
    const wa = screen.getDisplayNearestPoint(loc).workArea;
    x = Math.max(wa.x - a.x + h / 2, Math.min(x, wa.x + wa.width - a.x - h / 2));
    const top = wa.y;
    const bottom = wa.y + wa.height;
    y = Math.max(top - a.y + h, Math.min(y, bottom - a.y - h));
    x = Math.round(x); y = Math.round(y);
    // Under ~220 px of headroom (a 5-line card plus its tail), the
    // bubbles go under the feet instead.
    setBubblesBelow((y + a.y - h) - top < 220);

    const b = win.getBounds();
    if (b.x !== x || b.y !== y) {
      // setBounds with the fixed size, not setPosition: on a scaled display
      // Windows can round a moved window's size by a pixel each move.
      win.setBounds({ x, y, width: VIEW_WIDTH, height: VIEW_HEIGHT });
      pushGeom();
    }
    sm.position = { x, y };
  };

  const startDrag = () => {
    if (win.isDestroyed()) return;
    const loc = screen.getCursorScreenPoint();
    const b = win.getBounds();
    dragOffset = { x: loc.x - b.x, y: loc.y - b.y };
    prevDragPos = loc;
    prevDragTime = performance.now() / 1000;
    dragging = true;
    sm.setState("dragging");
    if (!dragTimer) dragTimer = setInterval(dragTick, 8);
  };

  const stopDrag = () => {
    dragging = false;
    if (dragTimer) { clearInterval(dragTimer); dragTimer = null; }
  };

  const mouseUp = () => {
    stopDrag();
    send({ type: "dragVelocity", vx: 0, vy: 0 });
    // Don't disturb the recording (headphone) animation when releasing a drag.
    if (sm.state === "recording") return;
    sm.setState("idle");
    send({ type: "springBack" });
  };

  // ---- Cursor polling ------------------------------------------------------

  // Always face the cursor, and let clicks fall through whenever it isn't on
  // Nikxel or a bubble. The renderer only sees the pointer over its own
  // window, so main polls the global position and hands it over, like the
  // Swift tick() reading NSEvent.mouseLocation each frame.
  // Outside the window only the side matters (which way to face), so the
  // renderer hears about a move out there only when the side flips.
  let lastCursor = "";
  const pollCursor = () => {
    if (win.isDestroyed() || !win.isVisible()) return;
    const p = screen.getCursorScreenPoint();
    const b = win.getBounds();
    let x = p.x - b.x, y = p.y - b.y;
    if (x < 0 || y < 0 || x >= b.width || y >= b.height) { x = x < b.width / 2 ? -1 : b.width + 1; y = -1; }
    const key = `${x},${y}`;
    if (key === lastCursor) return;
    // Coming in from outside: re-assert click-through before it matters.
    if (lastCursor.endsWith(",-1") && y !== -1) applyInteractive();
    lastCursor = key;
    send({ type: "cursor", x, y });
  };
  const cursorTimer = setInterval(pollCursor, 33);   // the renderer draws at 30 fps
  screen.on("display-metrics-changed", applyInteractive);
  screen.on("display-added", applyInteractive);
  screen.on("display-removed", applyInteractive);

  // ---- Events from the renderer -------------------------------------------

  const onEvent = (e: IpcMainEvent, evt: FromRenderer) => {
    if (win.isDestroyed() || e.sender !== win.webContents || !evt || typeof evt !== "object") return;
    switch (evt.type) {
      case "ready": {
        // A fresh page (first load, or a reload after a renderer crash).
        initSent = false;
        loaded = false;
        lastGeom = "";
        lastCursor = "";
        // The new page starts click-through; match it.
        interactive = false;
        applyInteractive();
        loadSprites().then(async ({ sprite, fallback }) => {
          const [fontBold, fontMedium] = await Promise.all([
            readOrNull(resourcePath("fonts/DMSans-Bold.ttf")),
            readOrNull(resourcePath("fonts/DMSans-Medium.ttf")),
          ]);
          if (win.isDestroyed()) return;
          const g = geomFor(win.getBounds());
          lastGeom = `${g.waLeft},${g.waRight}`;
          sendNow({ type: "init", state: sm.state, avatarSize: Settings.avatarSize, bubblesBelow, geom: g,
                    sprite, fallback, fontBold, fontMedium });
          sendNow({ type: "reminderText", text: sticky.reminderText });
          sendNow({ type: "recording", startedAt: sticky.recording });
          sendNow({ type: "texter", name: sticky.texter });
          // A card already up survives a renderer reload.
          if (current && !queue.some(m => m.type === "card")) sendNow({ type: "card", card: wire(current.id, current.card) });
          initSent = true;
          const q = queue; queue = [];
          for (const m of q) sendNow(m);
        }).catch(err => diag("avatar", `init failed: ${err}`));
        break;
      }
      case "loaded":
        if (!loaded) {
          loaded = true;
          // Hide the avatar + start the dust BEFORE the window shows, so the
          // first frame on screen is already mid-puff (not a Nikxel flash).
          if (wantVisible && !win.isVisible()) {
            sendNow({ type: "puff" });
            showWindow();
          }
        }
        break;
      case "interactive":
        interactive = evt.on;
        stats.reports++;
        applyInteractive();
        break;
      case "press":
        lastPressAt = Date.now();
        stats.presses++;
        break;
      case "dragStart":
        startDrag();
        break;
      case "mouseUp":
        mouseUp();
        break;
      case "click":
        if (clickDecision(evt.moved, evt.second) === "chat") {
          clearTimeout(pendingClick);
          pendingClick = setTimeout(() => {
            const b = win.getBounds(), a = AVATAR_CENTER, h = halfChar();
            runSafely("onClick", () => handlers.onClick({ x: b.x + a.x - h, y: b.y + a.y - h, width: 2 * h, height: 2 * h }));
          }, 500);  // the OS default double-click interval, so a slow double-click never opens the box
        } else if (evt.moved >= 4) runSafely("onDrag", () => handlers.onDrag?.());
        break;
      case "doubleClick":
        // The first click's chat toggle is still waiting: a double-click leaves the box as it is.
        clearTimeout(pendingClick);
        stopDrag();
        runSafely("onDoubleClick", handlers.onDoubleClick);
        break;
      case "reminderTap":
        // Reminder bubble taps take priority over drag/double-click so a tap
        // on a bubble completes the reminder without engaging the recording
        // toggle. The renderer has already removed it.
        if (typeof evt.id === "string") runSafely("reminder tap", () => ui.reminderWasTapped(evt.id));
        break;
      case "cardTap": {
        // Tapping the card opens what it's about instead of picking Nikxel up.
        if (!current || current.id !== evt.id || current.card.buttons?.length) break;
        const action = current.card.action;
        current = null;   // before the action, which may raise the next card
        runSafely("card action", action);
        break;
      }
      case "cardButton": {
        // A question: only its buttons answer it.
        if (!current || current.id !== evt.id) break;
        const btn = current.card.buttons?.[evt.index];
        if (!btn) break;
        current = null;   // before the action, which may ask the next question
        runSafely(`card button "${btn.title}"`, btn.action);
        break;
      }
      case "cardGone":
        if (current?.id === evt.id) current = null;
        break;
    }
  };
  ipcMain.on("avatar:event", onEvent);

  const wire = (id: number, c: CardOptions): CardWire => {
    const lifetime = c.lifetime ?? 20;
    return {
      id,
      icon: c.icon ?? null,
      title: c.title,
      lines: c.lines,
      bulleted: !!c.bulleted,
      kind: c.kind ?? "info",
      lifetime: Number.isFinite(lifetime) ? lifetime : null,
      buttons: (c.buttons ?? []).map(b => b.title),
    };
  };

  // ---- State, sprites ------------------------------------------------------

  const onState = (s: NikxelState) => send({ type: "state", state: s });
  sm.on("state", onState);

  const reloadSprites = () => {
    loadSprites().then(s => send({ type: "sprites", ...s })).catch(e => diag("avatar", `sprite reload failed: ${e}`));
  };
  bus.on("spritesChanged", reloadSprites);

  const showWindow = () => {
    if (win.isDestroyed()) return;
    if (!win.isVisible()) win.showInactive();
    // Windows lets the taskbar and other topmost windows climb over a
    // topmost window; re-asserting puts Nikxel back on top.
    win.setAlwaysOnTop(true, "screen-saver");
    applyInteractive();
    pollCursor();
  };

  win.webContents.on("render-process-gone", (_e, details) => {
    diag("avatar", `renderer gone (${details.reason}); reloading`);
    stopDrag();
    initSent = false;
    if (!win.isDestroyed()) win.loadFile(rendererPath("avatar")).catch(err => diag("avatar", `reload failed: ${err}`));
  });

  win.on("closed", () => {
    stopDrag();
    clearInterval(cursorTimer);
    screen.off("display-metrics-changed", applyInteractive);
    screen.off("display-added", applyInteractive);
    screen.off("display-removed", applyInteractive);
    ipcMain.removeListener("avatar:event", onEvent);
    sm.off("state", onState);
    bus.off("spritesChanged", reloadSprites);
  });

  win.loadFile(rendererPath("avatar")).catch(err => diag("avatar", `load failed: ${err}`));

  // ---- The surface everything else talks to (via core/ui) -------------------

  const surface: AvatarWindow = {
    window: win,

    isVisible: () => wantVisible && !win.isDestroyed(),

    /// Where the character itself is on screen (the first-run tour points at it).
    avatarRect() {
      const b = win.getBounds(), a = AVATAR_CENTER, h = halfChar();
      return { x: b.x + a.x - h, y: b.y + a.y - h, width: 2 * h, height: 2 * h };
    },

    show() {
      wantVisible = true;
      if (!win.isDestroyed()) win.webContents.setBackgroundThrottling(false);
      if (loaded) showWindow();
    },

    hide() {
      wantVisible = false;
      if (dragging) mouseUp();
      // Hidden, the animation loop has nothing to draw: let Chromium park it.
      if (!win.isDestroyed()) { win.webContents.setBackgroundThrottling(true); win.hide(); }
    },

    /// Shows a notification card above the avatar. Replaces any card already
    /// on screen.
    ///
    /// `lifetime` is per-card on purpose: a MOM-ready nudge can go after a few
    /// seconds, but the 10pm digest fires when nobody is watching and has to
    /// still be there when they come back, and an error should wait to be read.
    showCard(c: CardOptions) {
      // A question waiting on an answer isn't knocked off by a passing notice.
      // ponytail: that notice is dropped, not queued; queue if it matters.
      if (current?.card.buttons?.length && !c.buttons?.length) return;
      const id = ++cardSeq;
      current = { id, card: c };
      send({ type: "card", card: wire(id, c) });
    },

    dismissCard() {
      if (!current) return;
      current = null;
      send({ type: "dismissCard" });
    },

    pushReminder(id: string, title: string) { send({ type: "pushReminder", id, title }); },
    dismissReminder(id: string) { send({ type: "dismissReminder", id }); },
    setReminderText(text: string | null) { sticky.reminderText = text; send({ type: "reminderText", text }); },
    setRecordingStartedAt(ms: number | null) { sticky.recording = ms; send({ type: "recording", startedAt: ms }); },
    setActiveTexter(name: string | null) { sticky.texter = name; send({ type: "texter", name }); },

    applyAvatarSize() {
      charSize = 156 * Settings.avatarSize;
      send({ type: "size", avatarSize: Settings.avatarSize });
    },

    reloadSprites,

    /// Pixel dust cloud appearance. Avatar is hidden for the first ~half of
    /// the animation, then pops in with a small spring-back bounce.
    triggerPuff() { send({ type: "puff" }); },

    /// One key-down from InputHandler, for the WPM overheat.
    recordKeystroke() { send({ type: "key" }); },

    /// A left press anywhere, from InputHandler's global hook. If the cursor
    /// was on Nikxel (the renderer said so) and the window never heard the
    /// press, Windows isn't delivering clicks to it: pick Nikxel up from here
    /// instead, so it can still be dragged and clicked.
    globalMouseDown() {
      if (!wantVisible || win.isDestroyed() || !win.isVisible() || !interactive || dragging) return;
      const at = Date.now();
      const p = screen.getCursorScreenPoint();
      setTimeout(() => {
        // The hook can be heard a little after the window's own report of the same press.
        if (lastPressAt >= at - 300 || dragging || win.isDestroyed()) return;
        stats.missed++;
        if (stats.missed === 1 || stats.missed % 20 === 0) {
          diag("avatar", `a press on Nikxel didn't reach its window (${stats.missed} so far); handled from the global hook. ${diagnostics()}`);
        }
        hookPress = { at, x: p.x, y: p.y };
        startDrag();
      }, 150);
    },

    globalMouseUp() {
      const press = hookPress;
      if (!press) return;
      hookPress = null;
      const p = screen.getCursorScreenPoint();
      mouseUp();
      // Same rule as a press the window saw: barely moved is a click.
      const moved = Math.hypot(p.x - press.x, p.y - press.y);
      if (clickDecision(moved, false) === "chat") {
        const b = win.getBounds(), a = AVATAR_CENTER, h = halfChar();
        runSafely("onClick", () => handlers.onClick({ x: b.x + a.x - h, y: b.y + a.y - h, width: 2 * h, height: 2 * h }));
      } else if (moved >= 4) runSafely("onDrag", () => handlers.onDrag?.());
    },

    diagnostics,
  };

  function diagnostics(): string {
    if (win.isDestroyed()) return "window gone";
    const b = win.getBounds(), c = screen.getCursorScreenPoint();
    const d = screen.getDisplayMatching(b);
    return `bounds ${b.x},${b.y} ${b.width}x${b.height} on a ${d.size.width}x${d.size.height} display at ${d.scaleFactor}x `
      + `(${screen.getAllDisplays().length} display(s)); cursor ${c.x - b.x},${c.y - b.y} in the window; `
      + `clickable=${interactive}, ${stats.reports} hover reports, ${stats.presses} presses, ${stats.missed} missed; `
      + `visible=${win.isVisible()}, state=${sm.state}`;
  }

  ui.setAvatar(surface);
  return surface;
}
