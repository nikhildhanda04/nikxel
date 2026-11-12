// Port of NikxelView.swift + NikxelCard.swift: everything the avatar window
// shows, drawn on one canvas at 60 fps. The Swift view is y-up from the
// bottom-left; this canvas is y-down from the top-left, so every y is flipped.
// Main (src/main/avatar/avatarWindow.ts) owns the window, drag and callbacks.

export {};

type NikxelState =
  | "idle" | "walk" | "typing" | "thinking" | "done" | "dragging" | "pounce" | "petted"
  | "alert" | "recording" | "momReady" | "writingMOM";
type CardKind = "info" | "success" | "warning" | "error";

interface CardWire {
  id: number;
  icon: string | null;
  title: string;
  lines: string[];
  bulleted: boolean;
  kind: CardKind;
  lifetime: number | null;
  buttons: string[];
}
interface Geom { waLeft: number; waRight: number }

type FromMain =
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
  | { type: "meeting"; on: boolean }
  | { type: "texter"; name: string | null };

type ToMain =
  | { type: "ready" }
  | { type: "loaded" }
  | { type: "interactive"; on: boolean }
  | { type: "dragStart" }
  | { type: "mouseUp" }
  | { type: "doubleClick" }
  | { type: "cardTap"; id: number }
  | { type: "cardButton"; id: number; index: number }
  | { type: "cardGone"; id: number }
  | { type: "reminderTap"; id: string };

declare global {
  interface Window {
    nikxel: { onMessage(cb: (msg: unknown) => void): void; send(evt: unknown): void };
  }
}

const bridge = window.nikxel;
const post = (m: ToMain) => bridge.send(m);

// ---------------------------------------------------------------------------
// Geometry and constants

const VIEW_W = 640;
const VIEW_H = 700;
const AVATAR_BOTTOM_INSET = 350;
/// Avatar centre. Sprite, shadow, bubbles and hit testing are all positioned
/// from here, so this is the only place the anchor is defined.
const AC = { x: VIEW_W / 2, y: VIEW_H - AVATAR_BOTTOM_INSET };

const FRAME = 64;
const FRAME_COUNT = 4;

// macOS system colours the Swift used.
const SYSTEM_YELLOW = [255, 204, 0];
const SYSTEM_BLUE = "rgb(0,122,255)";
const SYSTEM_GREEN = "rgb(52,199,89)";
const SYSTEM_ORANGE = "rgb(255,149,0)";
const rgba = (c: number[], a: number) => `rgba(${c[0]},${c[1]},${c[2]},${a})`;

const ACCENT: Record<CardKind, string> = {
  info: "rgb(77,115,230)",     // 0.30 0.45 0.90
  success: "rgb(43,158,92)",   // 0.17 0.62 0.36
  warning: "rgb(217,148,26)",  // 0.85 0.58 0.10
  error: "rgb(204,56,51)",     // 0.80 0.22 0.20
};

const CardMetrics = {
  maxWidth: 272,
  pad: 14,
  corner: 18,
  titleSize: 13.5,
  bodySize: 12.5,
  titleGap: 7,
  lineGap: 5,
  iconGap: 7,
  bulletDiameter: 4,
  bulletGap: 9,
  tailWidth: 16,
  tailHeight: 9,
  /// Gap between the tail's tip and the top of the sprite.
  liftAboveHead: 8,
  /// Cards are capped so a long error message can't grow past the top of
  /// the window and get clipped.
  maxLines: 5,
  buttonHeight: 24,
  buttonPadX: 12,
  buttonGap: 6,
};

const GlassMetrics = {
  pad: 16,
  fontSize: 14,
  dotDiameter: 7,
  dotGap: 10,
  maxWidth: 280,
  stepY: 48,
};

// ---------------------------------------------------------------------------
// Canvas

const canvas = document.getElementById("view") as HTMLCanvasElement;
const ctx = canvas.getContext("2d")!;
/// Offscreen layer for the sprite when it's tinted red, so the tint only
/// lands on Nikxel and not on the shadow or dust around it.
const layer = document.createElement("canvas");
const lctx = layer.getContext("2d")!;
let dpr = 0;

function fitCanvas(): void {
  const d = window.devicePixelRatio || 1;
  if (d === dpr) return;
  dpr = d;
  for (const c of [canvas, layer]) {
    c.width = Math.round(VIEW_W * d);
    c.height = Math.round(VIEW_H * d);
  }
}

// ---------------------------------------------------------------------------
// Fonts and text

const DM = `"DM Sans", "Segoe UI", sans-serif`;
const dmFont = (size: number, bold = false) => `${bold ? 700 : 500} ${size}px ${DM}`;
const sysFont = (size: number, weight: number) => `${weight} ${size}px "Segoe UI", system-ui, sans-serif`;
const emojiFont = (size: number) => `${size}px "Segoe UI Emoji", "Segoe UI", sans-serif`;

/// Bumped when a font finishes loading; layouts cached against an older
/// version are measured again.
let fontsVersion = 0;
const metricCache = new Map<string, { ascent: number; descent: number; height: number }>();

function fontMetrics(font: string): { ascent: number; descent: number; height: number } {
  let m = metricCache.get(font);
  if (!m) {
    ctx.save();
    ctx.font = font;
    const t = ctx.measureText("Hg");
    ctx.restore();
    const ascent = t.fontBoundingBoxAscent || t.actualBoundingBoxAscent;
    const descent = t.fontBoundingBoxDescent || t.actualBoundingBoxDescent;
    m = { ascent, descent, height: ascent + descent };
    metricCache.set(font, m);
  }
  return m;
}

function measure(font: string, s: string, spacing = 0): number {
  ctx.save();
  ctx.font = font;
  ctx.letterSpacing = `${spacing}px`;
  const w = ctx.measureText(s).width;
  ctx.restore();
  return w;
}

/// Word-wraps `text` to `maxW`, like NSAttributedString.boundingRect with
/// .byWordWrapping. Words wider than the line are broken by character.
function wrap(font: string, text: string, maxW: number): { lines: string[]; width: number } {
  ctx.save();
  ctx.font = font;
  const w = (s: string) => ctx.measureText(s).width;
  const lines: string[] = [];
  const isSpace = (s: string) => /^\s+$/.test(s);
  for (const para of text.split("\n")) {
    let line = "";
    for (const tok of para.split(/(\s+)/).filter(s => s.length > 0)) {
      if (w(line + tok) <= maxW) { line += tok; continue; }
      // Overflowing whitespace just ends the line.
      if (isSpace(tok)) { lines.push(line.trimEnd()); line = ""; continue; }
      if (line.trim() !== "") lines.push(line.trimEnd());
      line = "";
      if (w(tok) <= maxW) { line = tok; continue; }
      // A single word wider than the line: break it by character.
      for (const ch of Array.from(tok)) {
        if (line !== "" && w(line + ch) > maxW) { lines.push(line); line = ch; }
        else line += ch;
      }
    }
    lines.push(line.trimEnd());
  }
  const width = Math.max(0, ...lines.map(w));
  ctx.restore();
  return { lines, width };
}

/// Single line, cut with an ellipsis to fit (NSLineBreakMode.byTruncatingTail).
function truncate(font: string, s: string, maxW: number, spacing = 0): string {
  if (measure(font, s, spacing) <= maxW) return s;
  const chars = Array.from(s);
  let lo = 0, hi = chars.length;
  while (lo < hi) {
    const mid = Math.ceil((lo + hi) / 2);
    if (measure(font, chars.slice(0, mid).join("") + "…", spacing) <= maxW) lo = mid; else hi = mid - 1;
  }
  return chars.slice(0, lo).join("") + "…";
}

/// Draws one line of text whose line box starts at `top`.
function textAt(c: CanvasRenderingContext2D, font: string, s: string, x: number, top: number): void {
  c.font = font;
  c.textBaseline = "alphabetic";
  c.fillText(s, x, top + fontMetrics(font).ascent);
}

async function loadFonts(bold: Uint8Array | null, medium: Uint8Array | null): Promise<void> {
  const faces: [Uint8Array | null, string][] = [[bold, "700"], [medium, "500"]];
  await Promise.all(faces.map(async ([bytes, weight]) => {
    if (!bytes) return;
    try {
      const face = new FontFace("DM Sans", new Uint8Array(bytes).buffer, { weight });
      await face.load();
      document.fonts.add(face);
    } catch (e) {
      console.warn(`DM Sans ${weight} failed to load; using Segoe UI`, e);
    }
  }));
  metricCache.clear();
  fontsVersion++;
}

// ---------------------------------------------------------------------------
// Sprites

let spriteSheet: ImageBitmap | null = null;
let fallbackAvatar: ImageBitmap | null = null;
/// RGBA of the whole sheet, for alpha hit testing.
let sheetPixels: Uint8ClampedArray | null = null;
let sheetWidth = 0;
let sheetHeight = 0;

async function decode(bytes: Uint8Array | null): Promise<ImageBitmap | null> {
  if (!bytes) return null;
  try {
    return await createImageBitmap(new Blob([new Uint8Array(bytes)], { type: "image/png" }));
  } catch (e) {
    console.warn("couldn't decode image", e);
    return null;
  }
}

async function loadSprites(sprite: Uint8Array | null, fallback: Uint8Array | null): Promise<void> {
  const [sheet, fb] = await Promise.all([decode(sprite), decode(fallback)]);
  // The Swift fallback when nikxel_avatar.png is missing: a pink square.
  fallbackAvatar = fb;
  if (sheet) spriteSheet = sheet;
  // A swapped sheet invalidates the alpha mask, which is what hit-testing
  // uses -- a stale mask would make the new avatar clickable in the old
  // one's silhouette.
  sheetPixels = null;
  if (spriteSheet) {
    try {
      const c = document.createElement("canvas");
      c.width = spriteSheet.width;
      c.height = spriteSheet.height;
      const cc = c.getContext("2d", { willReadFrequently: true })!;
      cc.drawImage(spriteSheet, 0, 0);
      sheetPixels = cc.getImageData(0, 0, c.width, c.height).data;
      sheetWidth = c.width;
      sheetHeight = c.height;
    } catch (e) {
      console.warn("couldn't read sprite pixels; hit testing falls back to the box", e);
    }
  }
}

function stateRow(s: NikxelState): number {
  switch (s) {
    case "idle": case "walk": return 0;
    case "typing": case "writingMOM": return 1;
    case "thinking": return 2;
    case "done": return 3;
    case "dragging": return 4;
    case "pounce": return 5;
    case "petted": return 6;
    case "alert": return 7;
    case "recording": return 8;
    case "momReady": return 9;
  }
}

// ---------------------------------------------------------------------------
// View state (the NikxelView properties)

let currentState: NikxelState = "idle";
let facingRight = true;
let bounce = 0;   // up-positive, as in the Swift
let wiggle = 0;
let scale = 1;
/// Extra horizontal/vertical stretch while dragging (the mochi squash).
let stretchX = 1;
let stretchY = 1;

let frameIndex = 0;
let frameElapsed = 0;
let lastTick = performance.now() / 1000;

/// Sprite size: 156 px times the user's Avatar Size.
let charSize = 156;
const halfChar = () => charSize / 2;

/// Set by main when the avatar is too near the top of the screen for
/// anything to fit above its head.
let bubblesBelow = false;
let geom: Geom = { waLeft: -1e6, waRight: 1e6 };

/// Y (window coords, y-down) for something `off` above the head -- or, with
/// `bubblesBelow`, the same distance under the feet. Pass `h` when the y is
/// the item's top, so an item above the head sits on that line and a
/// flipped one hangs down from it.
function headY(off: number, h = 0): number {
  return bubblesBelow ? AC.y + halfChar() + off : AC.y - halfChar() - off - h;
}

let springActive = false;
let springStart = 0;
const springDuration = 0.45;

// Drag inertia
let dragVelocity = { x: 0, y: 0 };
let dragLagX = 0;
let dragLagY = 0;

// Overheat
let keyTimestamps: number[] = [];
const overheatWPM = 30;
const wpmWindow = 5.0;

let bubbleOpacity = 0;
let bubbleScale = 1;

// Calendar reminder bubble
let reminderText: string | null = null;
let reminderOpacity = 0;

// Meeting indicator (yellow dot)
let isInMeeting = false;
let meetingDotOpacity = 0;

// Active texter bubble (chatbot)
let activeTexterName: string | null = null;
let texterOpacity = 0;

// Recording timer: Date.now() ms when it started.
let recordingStartedAt: number | null = null;

// Reminder bubbles (transient, tap-to-complete)
interface Rect { x: number; y: number; w: number; h: number }
const contains = (r: Rect, p: { x: number; y: number }) =>
  r.w > 0 && p.x >= r.x && p.x <= r.x + r.w && p.y >= r.y && p.y <= r.y + r.h;
const ZERO: Rect = { x: 0, y: 0, w: 0, h: 0 };

interface ReminderBubble { id: string; title: string; addedAt: number; opacity: number; hitRect: Rect }
let reminderBubbles: ReminderBubble[] = [];
const reminderBubbleLifetime = 30;
const reminderFadeOut = 0.4;
const reminderFadeIn = 0.3;

// Notification card
interface CardLayout {
  version: number;
  iconW: number;
  titleW: number;
  titleLines: string[];
  titleH: number;
  firstLineH: number;
  bulletIndent: number;
  measured: { lines: string[]; height: number; width: number; firstLineH: number }[];
  btnWs: number[];
  rowH: number;
  textW: number;
  cardW: number;
  cardH: number;
}
interface Card extends CardWire {
  addedAt: number;
  opacity: number;
  hitRect: Rect;
  buttonRects: Rect[];
  layout: CardLayout | null;
}
let card: Card | null = null;
const cardFadeIn = 0.45;
const cardFadeOut = 0.6;

// Cloud puff (appearance animation)
let puffActive = false;
let puffStart = 0;
const puffDuration = 1.3;
const puffRevealAt = 0.54; // 0.54 * 1.3 ≈ 0.7s of dust before Nikxel
let avatarHiddenByPuff = false;

// Pointer, in window coords. From main's poll and from our own mouse events.
let pointer = { x: -1e6, y: -1e6 };
let pressOnAvatar = false;
let localDragging = false;
let interactive = false;

function now(): number { return performance.now() / 1000; }

function triggerSpringBack(): void { springActive = true; springStart = now(); }

/// Pixel dust cloud appearance. Avatar is hidden for the first ~half of the
/// animation, then pops in with a small spring-back bounce while the dust
/// continues outward and fades.
function triggerPuff(): void {
  puffActive = true;
  puffStart = now();
  avatarHiddenByPuff = true;
}

function pushReminder(id: string, title: string): void {
  // Dedup: ignore if already on screen.
  if (reminderBubbles.some(b => b.id === id)) return;
  reminderBubbles.push({ id, title, addedAt: now(), opacity: 0, hitRect: ZERO });
}

function dismissReminder(id: string): void {
  reminderBubbles = reminderBubbles.filter(b => b.id !== id);
}

function removeCard(notifyMain: boolean): void {
  if (card && notifyMain) post({ type: "cardGone", id: card.id });
  card = null;
}

// ---------------------------------------------------------------------------
// Hit testing

/// Index of the card button under `p`, if any.
function cardButton(p: { x: number; y: number }): number | null {
  if (!card || card.opacity <= 0.05) return null;
  const i = card.buttonRects.findIndex(r => contains(r, p));
  return i >= 0 ? i : null;
}

function hitTestCard(p: { x: number; y: number }): boolean {
  return !!card && card.opacity > 0.05 && contains(card.hitRect, p);
}

function hitTestReminderBubble(p: { x: number; y: number }): string | null {
  for (let i = reminderBubbles.length - 1; i >= 0; i--) {
    if (contains(reminderBubbles[i].hitRect, p)) return reminderBubbles[i].id;
  }
  return null;
}

// A few pixels of slack around opaque pixels so clicking the very edge of the
// character still registers, without re-engaging the empty padding.
const hitTolerancePx = 2;

/// True only when `p` lands on an opaque pixel of the current sprite frame,
/// matching the live transform (facing/scale/offset). The window is mostly
/// empty padding; only the character and its bubbles take clicks.
function hitTestAvatar(p: { x: number; y: number }): boolean {
  if (avatarHiddenByPuff) return false;
  const signX = facingRight ? 1 : -1;
  const sx = Math.max(scale * stretchX, 0.01);
  const sy = Math.max(scale * stretchY, 0.01);
  // Invert the draw transform back into sprite-rect space [0, charSize].
  const qx = (p.x - (AC.x + wiggle)) / (signX * sx) + halfChar();
  const qy = (p.y - (AC.y - bounce)) / sy + halfChar();
  if (qx < 0 || qx > charSize || qy < 0 || qy > charSize) return false;

  // No sprite sheet -> fall back to the bounding box.
  if (!spriteSheet || !sheetPixels) return true;

  const mf = currentState === "dragging" ? 1 : FRAME_COUNT;
  const col = frameIndex % mf;
  const row = stateRow(currentState);
  // Canvas is y-down like the bitmap, so no row flip.
  const baseCol = Math.min(63, Math.max(0, Math.floor(qx / charSize * 64)));
  const baseRow = Math.min(63, Math.max(0, Math.floor(qy / charSize * 64)));
  for (let dr = -hitTolerancePx; dr <= hitTolerancePx; dr++) {
    for (let dc = -hitTolerancePx; dc <= hitTolerancePx; dc++) {
      const r = baseRow + dr, c = baseCol + dc;
      if (r < 0 || r >= 64 || c < 0 || c >= 64) continue;
      const px = col * FRAME + c, py = row * FRAME + r;
      if (px >= sheetWidth || py >= sheetHeight) continue;
      if (sheetPixels[(py * sheetWidth + px) * 4 + 3] > 24) return true;
    }
  }
  return false;
}

function isOverheated(t: number): boolean {
  const count = keyTimestamps.filter(k => t - k < wpmWindow).length;
  return count / 5.0 * (60.0 / wpmWindow) > overheatWPM;
}

// ---------------------------------------------------------------------------
// Tick

const FPS: Record<NikxelState, number> = {
  idle: 3, walk: 8, typing: 8, thinking: 2.5, done: 6, dragging: 0,
  pounce: 8, petted: 3, alert: 6, recording: 4, momReady: 6, writingMOM: 8,
};

function easeOutBounce(x: number): number {
  const t = Math.max(0, Math.min(1, x));
  const n1 = 7.5625, d1 = 2.75;
  if (t < 1 / d1) return n1 * t * t;
  if (t < 2 / d1) { const t2 = t - 1.5 / d1; return n1 * t2 * t2 + 0.75; }
  if (t < 2.5 / d1) { const t2 = t - 2.25 / d1; return n1 * t2 * t2 + 0.9375; }
  const t2 = t - 2.625 / d1; return n1 * t2 * t2 + 0.984375;
}

const fade = (v: number, target: number, step: number) =>
  target > v ? Math.min(target, v + step) : target < v ? Math.max(target, v - step) : v;

function tick(): void {
  const t = now();
  // Clamp the step after a hidden spell (rAF doesn't run while hidden).
  const dt = Math.min(0.25, Math.max(0, t - lastTick));
  lastTick = t;

  // Always face the cursor.
  if (currentState !== "dragging") facingRight = pointer.x > AC.x;

  // Let clicks fall through to apps behind us whenever the cursor isn't on
  // Nikxel or one of the bubbles.
  const nowInteractive = localDragging || currentState === "dragging"
    || hitTestReminderBubble(pointer) !== null
    || hitTestCard(pointer)
    || hitTestAvatar(pointer);
  if (nowInteractive !== interactive) {
    interactive = nowInteractive;
    post({ type: "interactive", on: interactive });
  }

  // Overheat decay (prune old keystrokes)
  keyTimestamps = keyTimestamps.filter(k => t - k < wpmWindow);

  // Frame animation
  const fps = FPS[currentState];
  if (fps > 0 && spriteSheet) {
    const mf = currentState === "dragging" ? 1 : FRAME_COUNT;
    frameElapsed += dt;
    const interval = 1.0 / fps;
    while (frameElapsed >= interval) { frameElapsed -= interval; frameIndex = (frameIndex + 1) % mf; }
  }

  // Drag inertia: the body trails the pointer and springs back when it
  // stops. (The Swift tracked dragVelocity but never fed it into the lag.)
  {
    const k = 0.012;
    const targetX = -dragVelocity.x * k;
    const targetY = dragVelocity.y * k;   // velocity is y-down, lag is up-positive
    const ease = Math.min(1, dt * 14);
    dragLagX += (targetX - dragLagX) * ease;
    dragLagY += (targetY - dragLagY) * ease;
  }

  // Transform animation
  stretchX = 1; stretchY = 1;
  switch (currentState) {
    case "idle": bounce = Math.sin(t * 3) * 2; scale = 1; wiggle = 0; break;
    case "walk": bounce = Math.sin(t * 8) * 3; scale = 1; wiggle = 0; break;
    case "typing": wiggle = Math.sin(t * 25) * 2.5; bounce = Math.sin(t * 6) * 1.5; scale = 1; break;
    case "thinking": bounce = Math.sin(t * 1.5) * 1; scale = 1; wiggle = 0; break;
    case "done": {
      const p = t % 0.5;
      bounce = p < 0.25 ? p * 4 * 40 : (0.5 - p) * 4 * 40;
      scale = 1.1; wiggle = 0; break;
    }
    case "dragging": {
      scale = 1.2;
      wiggle = Math.max(-18, Math.min(18, dragLagX));
      bounce = Math.max(-12, Math.min(12, dragLagY));
      // Mochi: stretch along the way it's being pulled, squash across it.
      const ax = Math.abs(wiggle) / 18, ay = Math.abs(bounce) / 12;
      stretchX = 1 + 0.12 * ax - 0.06 * ay;
      stretchY = 1 + 0.12 * ay - 0.06 * ax;
      break;
    }
    case "pounce": {
      const phase = (t % 0.7) / 0.7;
      if (phase < 0.3) { scale = 1.0; bounce = 0; }
      else if (phase < 0.5) { scale = 1.15; bounce = (phase - 0.3) * 80; }
      else if (phase < 0.8) { scale = 1.05; bounce = (0.8 - phase) * 40; }
      else { scale = 1.0; bounce = 0; }
      wiggle = 0; break;
    }
    case "petted": bounce = Math.sin(t * 2.5) * 1.5; scale = 1; wiggle = 0; break;
    case "alert":
      bounce = Math.abs(Math.sin(t * 8)) * 4;
      wiggle = Math.sin(t * 12) * 1.5;
      scale = 1; break;
    case "recording": bounce = Math.sin(t * 2) * 1.2; scale = 1; wiggle = 0; break;
    case "momReady": {
      const p = t % 0.6;
      bounce = p < 0.3 ? p * 4 * 30 : (0.6 - p) * 4 * 30;
      scale = 1.08; wiggle = 0; break;
    }
    case "writingMOM":
      wiggle = Math.sin(t * 25) * 2.5;
      bounce = Math.sin(t * 6) * 1.5;
      scale = 1; break;
  }

  // Spring-back scale
  if (springActive) {
    const progress = (t - springStart) / springDuration;
    if (progress >= 1.0) springActive = false;
    else scale = 1.2 + easeOutBounce(progress) * (1.0 - 1.2);
  }

  reminderOpacity = fade(reminderOpacity, reminderText !== null ? 1 : 0, dt * 5.0);
  texterOpacity = fade(texterOpacity, activeTexterName !== null ? 1 : 0, dt * 6.0);
  meetingDotOpacity = fade(meetingDotOpacity, isInMeeting ? 1 : 0, dt * 4.0);

  // Reminder bubbles fade + GC
  for (const b of reminderBubbles) {
    const age = t - b.addedAt;
    if (age < 0) b.opacity = 0;
    else if (age < reminderFadeIn) b.opacity = age / reminderFadeIn;
    else if (age > reminderBubbleLifetime - reminderFadeOut) {
      b.opacity = Math.max(0, Math.min(1, (reminderBubbleLifetime - age) / reminderFadeOut));
    } else b.opacity = 1;
  }
  reminderBubbles = reminderBubbles.filter(b => t - b.addedAt <= reminderBubbleLifetime);

  if (card) {
    const age = t - card.addedAt;
    // A null lifetime means "stay until clicked" -- used by errors and questions.
    const finite = card.lifetime !== null;
    const life = card.lifetime ?? Infinity;
    let target: number;
    if (age < cardFadeIn) target = age / cardFadeIn;
    else if (finite && age > life - cardFadeOut) target = Math.max(0, (life - age) / cardFadeOut);
    else target = 1;
    if (finite && age > life) removeCard(true);
    else card.opacity = target;
  }

  // Bubble animation (thinking dots only)
  const bubbleTarget = currentState === "thinking" ? 1 : 0;
  if (bubbleTarget !== bubbleOpacity) {
    const fadeSpeed = 6.0;
    if (bubbleTarget > bubbleOpacity) {
      bubbleOpacity = Math.min(bubbleTarget, bubbleOpacity + dt * fadeSpeed);
      if (bubbleOpacity >= 1) bubbleOpacity = 1;
      const p = bubbleOpacity;
      bubbleScale = 0.8 + 0.2 * p + 0.15 * Math.sin(p * Math.PI) * (1 - p);
    } else {
      bubbleOpacity = Math.max(bubbleTarget, bubbleOpacity - dt * fadeSpeed);
      bubbleScale = bubbleOpacity;
    }
  }
}

// ---------------------------------------------------------------------------
// Draw

function circle(c: CanvasRenderingContext2D, x: number, y: number, r: number): void {
  c.beginPath();
  c.arc(x, y, r, 0, Math.PI * 2);
  c.fill();
}

function drawCharacter(c: CanvasRenderingContext2D): void {
  const sx = (facingRight ? 1 : -1) * scale * stretchX;
  const sy = scale * stretchY;
  c.save();
  c.imageSmoothingEnabled = false;
  c.translate(AC.x + wiggle, AC.y - bounce);
  c.scale(sx, sy);
  const h = halfChar();
  if (spriteSheet) {
    const mf = currentState === "dragging" ? 1 : FRAME_COUNT;
    const fx = (frameIndex % mf) * FRAME;
    const fy = stateRow(currentState) * FRAME;
    c.drawImage(spriteSheet, fx, fy, FRAME, FRAME, -h, -h, charSize, charSize);
  } else if (fallbackAvatar) {
    c.drawImage(fallbackAvatar, -h, -h, charSize, charSize);
  } else {
    c.fillStyle = "rgb(255,45,85)";   // systemPink
    c.fillRect(-h, -h, charSize, charSize);
  }
  c.restore();
}

function draw(): void {
  fitCanvas();
  ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
  ctx.clearRect(0, 0, VIEW_W, VIEW_H);
  ctx.imageSmoothingEnabled = false;

  const cx = AC.x, cy = AC.y;
  const h = halfChar();
  const t = now();

  // Drop shadow
  if (currentState !== "dragging") {
    const charBottom = cy + h;
    const alpha = 0.12 - (bounce > 0 ? bounce / 400 : 0);
    ctx.save();
    ctx.fillStyle = `rgba(0,0,0,${Math.max(0, alpha)})`;
    ctx.beginPath();
    ctx.ellipse(cx, charBottom - 2, h * 0.54, 6, 0, 0, Math.PI * 2);
    ctx.fill();
    ctx.restore();
  }

  const hot = currentState !== "dragging" && isOverheated(t);

  // Character (skipped while hidden by the puff)
  if (!avatarHiddenByPuff) {
    if (hot) {
      // Overheat red tint, on the sprite's own pixels only.
      const wpm = keyTimestamps.length / 5.0 * (60.0 / wpmWindow);
      const intensity = Math.min(1.0, (wpm - overheatWPM) / 30.0);
      lctx.setTransform(dpr, 0, 0, dpr, 0, 0);
      lctx.clearRect(0, 0, VIEW_W, VIEW_H);
      drawCharacter(lctx);
      lctx.save();
      lctx.globalCompositeOperation = "source-atop";
      lctx.fillStyle = `rgba(255,0,0,${intensity * 0.5})`;
      lctx.fillRect(cx + wiggle - h, cy - bounce - h, charSize, charSize);
      lctx.restore();
      ctx.save();
      ctx.setTransform(1, 0, 0, 1, 0, 0);
      ctx.drawImage(layer, 0, 0);
      ctx.restore();
    } else {
      drawCharacter(ctx);
    }
  }

  // Pixel dust puff (appearance animation, drawn on top of avatar)
  if (puffActive) drawPixelPuff(cx, cy, t);

  if (hot) drawSteam(cx, cy, t);

  // Recording indicator (red pulsing dot + elapsed timer)
  if (currentState === "recording" && recordingStartedAt !== null) {
    const elapsed = Math.max(0, (Date.now() - recordingStartedAt) / 1000);
    const mins = Math.floor(elapsed / 60);
    const secs = Math.floor(elapsed) % 60;
    const timer = `${mins}:${String(secs).padStart(2, "0")}`;

    const pulse = 0.7 + 0.3 * Math.sin(t * 4);
    const dotRadius = 5;
    const dotX = cx - 28;
    const dotY = headY(16);
    ctx.save();
    ctx.fillStyle = `rgba(255,0,0,${pulse})`;
    circle(ctx, dotX, dotY, dotRadius);

    // Timer text: white with a thin black outline.
    const font = sysFont(14, 600);
    const m = fontMetrics(font);
    ctx.font = font;
    ctx.textBaseline = "alphabetic";
    const base = dotY - m.height / 2 + m.ascent;
    ctx.lineJoin = "round";
    ctx.lineWidth = 0.84;
    ctx.strokeStyle = "black";
    ctx.strokeText(timer, dotX + 10, base);
    ctx.fillStyle = "white";
    ctx.fillText(timer, dotX + 10, base);
    ctx.restore();
  }

  // Meeting indicator (yellow dot above avatar)
  if (meetingDotOpacity > 0.01) {
    const dotRadius = 6;
    const dotY = headY(14);
    ctx.save();
    // Outer glow
    ctx.fillStyle = rgba(SYSTEM_YELLOW, meetingDotOpacity * 0.3);
    circle(ctx, cx, dotY, dotRadius + 3);
    // Inner dot
    ctx.fillStyle = rgba(SYSTEM_YELLOW, meetingDotOpacity);
    circle(ctx, cx, dotY, dotRadius);
    ctx.restore();
  }

  drawCard(cx);

  // MOM ready sparkle
  if (currentState === "momReady") {
    for (let i = 0; i < 5; i++) {
      const phase = (t * 3 + i * 0.7) % 1.0;
      const angle = i * Math.PI * 2 / 5;
      const dist = 30 + phase * 25;
      const sx = cx + Math.cos(angle) * dist;
      const sy = cy - Math.sin(angle) * dist - 10;
      ctx.fillStyle = rgba(SYSTEM_YELLOW, (1.0 - phase) * 0.9);
      circle(ctx, sx, sy, 2);
    }
  }

  // Thinking dots (on top of character)
  if (currentState === "thinking" && bubbleOpacity > 0.01) {
    ctx.save();
    ctx.globalAlpha = bubbleOpacity;
    const dotY = headY(22);
    const dotSpacing = 16;
    const dotRadius = 5;
    const dotCount = Math.min(3, frameIndex + 1);
    for (let i = 0; i < dotCount; i++) {
      const dx = cx + (i - 1) * dotSpacing;
      ctx.fillStyle = "white";
      circle(ctx, dx, dotY, dotRadius + 2);
      ctx.fillStyle = "black";
      circle(ctx, dx, dotY, dotRadius);
    }
    ctx.restore();
  }

  // The Mac draws these as Liquid Glass subviews, on top of everything.
  drawBubbles(cx);
}

// ---------------------------------------------------------------------------
// Glass bubbles: calendar ping, texter, reminders stack, overflow pill.
// Liquid Glass (a refracting clear pill) doesn't exist on Windows and a
// transparent window can't blur what's behind it, so this is a translucent
// dark pill with a hairline edge: same size, layout and text.

interface PillSize { w: number; h: number; text: string; textH: number; version: number }
const pillCache = new Map<string, PillSize>();

function pillSize(title: string): PillSize {
  const hit = pillCache.get(title);
  if (hit && hit.version === fontsVersion) return hit;
  const { pad, dotDiameter, dotGap, maxWidth } = GlassMetrics;
  const font = dmFont(GlassMetrics.fontSize);
  const tw = measure(font, title, 0.1);
  const th = fontMetrics(font).height;
  const contentW = Math.min(maxWidth - pad * 2, dotDiameter + dotGap + tw);
  const contentH = Math.max(dotDiameter, th);
  const w = contentW + pad * 2, h = contentH + pad * 2;
  const labelW = w - (pad + dotDiameter + dotGap) - pad;
  const s: PillSize = { w, h, text: truncate(font, title, labelW, 0.1), textH: th, version: fontsVersion };
  if (pillCache.size > 64) pillCache.clear();
  pillCache.set(title, s);
  return s;
}

function glassPill(x: number, y: number, w: number, h: number, alpha: number): void {
  ctx.save();
  ctx.globalAlpha = alpha;
  ctx.shadowColor = "rgba(0,0,0,0.18)";
  ctx.shadowBlur = 10 * dpr;
  ctx.shadowOffsetY = 2 * dpr;
  ctx.fillStyle = "rgba(28,28,32,0.52)";
  ctx.beginPath();
  ctx.roundRect(x, y, w, h, h / 2);
  ctx.fill();
  ctx.shadowColor = "transparent";
  ctx.strokeStyle = "rgba(255,255,255,0.28)";
  ctx.lineWidth = 1;
  ctx.beginPath();
  ctx.roundRect(x + 0.5, y + 0.5, w - 1, h - 1, (h - 1) / 2);
  ctx.stroke();
  ctx.restore();
}

/// White text with a subtle shadow for legibility against varied wallpapers.
function pillText(font: string, s: string, x: number, top: number, alpha: number, spacing: number): void {
  ctx.save();
  ctx.globalAlpha = alpha;
  ctx.fillStyle = "white";
  ctx.letterSpacing = `${spacing}px`;
  ctx.shadowColor = "rgba(0,0,0,0.35)";
  ctx.shadowOffsetY = 1 * dpr;
  ctx.shadowBlur = 2 * dpr;
  textAt(ctx, font, s, x, top);
  ctx.restore();
}

/// One bubble: accent dot + title, `top` is its upper edge.
function drawGlassBubble(title: string, dotColor: string, cx: number, top: number, alpha: number): Rect {
  const s = pillSize(title);
  const { pad, dotDiameter, dotGap } = GlassMetrics;
  const x = cx - s.w / 2;
  glassPill(x, top, s.w, s.h, alpha);
  ctx.save();
  ctx.globalAlpha = alpha;
  ctx.fillStyle = dotColor;
  circle(ctx, x + pad + dotDiameter / 2, top + s.h / 2, dotDiameter / 2);
  ctx.restore();
  pillText(dmFont(GlassMetrics.fontSize), s.text, x + pad + dotDiameter + dotGap, top + (s.h - s.textH) / 2, alpha, 0.1);
  return { x, y: top, w: s.w, h: s.h };
}

function drawBubbles(cx: number): void {
  // --- Calendar bubble (single, beneath the reminder stack) ---
  if (reminderText !== null && reminderOpacity > 0.001) {
    const s = pillSize(reminderText);
    drawGlassBubble(reminderText, SYSTEM_BLUE, cx, headY(24, s.h), reminderOpacity);
  }

  // --- Texter bubble (who's texting via chatbot, above avatar) ---
  if (activeTexterName !== null && texterOpacity > 0.001) {
    const displayText = `💬 ${activeTexterName} is texting...`;
    const s = pillSize(displayText);
    drawGlassBubble(displayText, SYSTEM_GREEN, cx, headY(36, s.h), texterOpacity);
  }

  // --- Reminders stack (3 visible, newest top) ---
  // baseY is the bottom-most visible bubble's centre. Below the feet the
  // stack grows downward.
  const visibleCount = Math.min(3, reminderBubbles.length);
  const startIdx = reminderBubbles.length - visibleCount;
  const baseY = headY(52);
  const stepY = GlassMetrics.stepY * (bubblesBelow ? 1 : -1);   // y-down

  // Clear hit rects first; repopulate for the visible ones.
  for (const b of reminderBubbles) b.hitRect = ZERO;
  for (let displayIdx = 0; displayIdx < visibleCount; displayIdx++) {
    const b = reminderBubbles[startIdx + displayIdx];
    const s = pillSize(b.title);
    const centerY = baseY + displayIdx * stepY;
    b.hitRect = drawGlassBubble(b.title, SYSTEM_ORANGE, cx, centerY - s.h / 2, b.opacity);
  }

  // --- Overflow pill above the top bubble ---
  const overflow = reminderBubbles.length - visibleCount;
  if (overflow > 0 && visibleCount > 0) {
    const font = dmFont(11, true);
    const label = `+${overflow} more`;
    const tw = measure(font, label, 0.3);
    const th = fontMetrics(font).height;
    const bw = tw + 22, bh = th + 12;
    const lastY = baseY + (visibleCount - 1) * stepY;
    const top = bubblesBelow ? lastY + 34 : lastY - 34 - bh;
    const x = cx - bw / 2;
    glassPill(x, top, bw, bh, 1);
    pillText(font, label, x + (bw - tw) / 2, top + (bh - th) / 2, 1, 0.3);
  }
}

// ---------------------------------------------------------------------------
// Card (NikxelCard.swift): the white speech bubble above the avatar used for
// "MOM ready", failures, questions and the end-of-day digest.

function layoutCard(c: Card): CardLayout {
  if (c.layout && c.layout.version === fontsVersion) return c.layout;
  const M = CardMetrics;
  const titleFont = dmFont(M.titleSize, true);
  const bodyFont = dmFont(M.bodySize);

  // --- Measure -------------------------------------------------------
  const iconW = c.icon ? Math.ceil(measure(emojiFont(M.titleSize + 1), c.icon)) + M.iconGap : 0;
  const titleW = Math.ceil(measure(titleFont, c.title));

  // Body text starts after the bullet column when bulleted.
  const bulletIndent = c.bulleted ? M.bulletDiameter + M.bulletGap : 0;
  const maxBodyW = M.maxWidth - M.pad * 2 - bulletIndent;
  const bodyLH = fontMetrics(bodyFont).height;

  const measured = c.lines.slice(0, M.maxLines).map(raw => {
    const r = wrap(bodyFont, raw, maxBodyW);
    return { lines: r.lines, height: Math.ceil(r.lines.length * bodyLH), width: Math.ceil(r.width), firstLineH: Math.ceil(bodyLH) };
  });

  const widestBody = Math.max(0, ...measured.map(m => m.width));
  const btnFont = sysFont(M.bodySize, 600);
  const btnWs = c.buttons.map(b => Math.ceil(measure(btnFont, b)) + M.buttonPadX * 2);
  const rowW = btnWs.reduce((a, b) => a + b, 0) + Math.max(0, btnWs.length - 1) * M.buttonGap;
  const rowH = c.buttons.length === 0 ? 0 : M.buttonHeight + M.titleGap + 3;
  // Buttons win over the width cap: a button hanging off the card is worse
  // than a slightly wider card.
  const textW = Math.max(rowW, Math.min(M.maxWidth - M.pad * 2,
    Math.max(iconW + titleW, widestBody + bulletIndent)));
  // Titles wrap rather than clip ("Send this meeting's tasks to Go…").
  const titleLH = fontMetrics(titleFont).height;
  const titleLines = wrap(titleFont, c.title, textW - iconW).lines;
  const titleH = Math.ceil(titleLines.length * titleLH);

  let bodyH = 0;
  measured.forEach((m, i) => { bodyH += m.height + (i > 0 ? M.lineGap : 0); });

  const cardW = textW + M.pad * 2;
  const cardH = titleH + (measured.length === 0 ? 0 : M.titleGap + bodyH) + rowH + M.pad * 2;
  c.layout = {
    version: fontsVersion, iconW, titleW, titleLines, titleH, firstLineH: Math.ceil(titleLH),
    bulletIndent, measured, btnWs, rowH, textW, cardW, cardH,
  };
  return c.layout;
}

function drawCard(cx: number): void {
  const c = card;
  if (!c || c.opacity <= 0.001) {
    if (c) { c.hitRect = ZERO; c.buttonRects = []; }
    return;
  }
  const M = CardMetrics;
  const L = layoutCard(c);
  const { cardW, cardH, iconW, titleH, bulletIndent } = L;

  // Centred on the avatar, but slid sideways to stay on screen when the
  // avatar sits at an edge -- otherwise a card's buttons end up off it.
  let cardX = cx - cardW / 2;
  const lo = geom.waLeft + 8;
  const hi = geom.waRight - 8 - cardW;
  cardX = Math.max(lo, Math.min(cardX, hi));
  cardX = Math.max(0, Math.min(cardX, VIEW_W - cardW));
  const cardY = headY(M.liftAboveHead + M.tailHeight, cardH);   // top edge

  // --- Card + tail as one path, so the shadow wraps both and no seam shows
  //     where the tail meets the card --------------------------------------
  ctx.save();
  ctx.globalAlpha = c.opacity;
  ctx.beginPath();
  ctx.roundRect(cardX, cardY, cardW, cardH, M.corner);
  // Offset left of centre, the way a speech tail sits.
  // Slid cards keep the tail over the avatar.
  const tailMidX = Math.abs(cardX - (cx - cardW / 2)) < 1
    ? cardX + Math.min(cardW * 0.28, 46)
    : Math.max(cardX + 18, Math.min(cx, cardX + cardW - 18));
  // The tail points at the avatar: down from the card's bottom edge, or up
  // from its top when the card hangs below the feet. Both wound clockwise,
  // like roundRect, so the overlap fills under the nonzero rule.
  const edge = bubblesBelow ? cardY : cardY + cardH;
  const dir = bubblesBelow ? -1 : 1;
  const L1 = { x: tailMidX - M.tailWidth / 2, y: edge - dir };
  const R1 = { x: tailMidX + M.tailWidth / 2, y: edge - dir };
  const tip = { x: tailMidX - M.tailWidth / 2 + 3, y: edge + dir * M.tailHeight };
  const [a, b] = bubblesBelow ? [R1, L1] : [L1, R1];
  ctx.moveTo(a.x, a.y);
  ctx.lineTo(b.x, b.y);
  ctx.lineTo(tip.x, tip.y);
  ctx.closePath();
  // Canvas shadows aren't scaled by the transform; the backing store is.
  ctx.shadowOffsetY = 3 * dpr;
  ctx.shadowBlur = 14 * dpr;
  ctx.shadowColor = "rgba(0,0,0,0.20)";
  ctx.fillStyle = "white";
  ctx.fill("nonzero");
  ctx.restore();

  // --- Text, outside the shadowed state so it isn't blurred with the card
  ctx.save();
  ctx.globalAlpha = c.opacity;

  const titleTop = cardY + M.pad;
  const titleFont = dmFont(M.titleSize, true);
  const titleLH = fontMetrics(titleFont).height;
  if (c.icon) {
    // Nudged down a touch: emoji sit high on their line box next to text.
    // On the first line of a wrapped title, not the last.
    const iconFont = emojiFont(M.titleSize + 1);
    const im = fontMetrics(iconFont);
    const iconBottom = titleTop + L.firstLineH + 1;
    ctx.fillStyle = "black";
    textAt(ctx, iconFont, c.icon, cardX + M.pad, iconBottom - im.height);
  }
  ctx.fillStyle = "rgb(26,26,26)";   // white 0.10
  L.titleLines.forEach((line, i) => textAt(ctx, titleFont, line, cardX + M.pad + iconW, titleTop + i * titleLH));

  const bodyFont = dmFont(M.bodySize);
  const bodyLH = fontMetrics(bodyFont).height;
  let lineTop = titleTop + titleH + M.titleGap;
  for (const m of L.measured) {
    if (c.bulleted) {
      // Centred on the first line of text, not on the whole block, so a
      // wrapped bullet keeps its dot beside the first line.
      ctx.fillStyle = ACCENT[c.kind];
      circle(ctx, cardX + M.pad + 1 + M.bulletDiameter / 2, lineTop + m.firstLineH / 2, M.bulletDiameter / 2);
    }
    ctx.fillStyle = "rgb(66,66,66)";   // white 0.26
    m.lines.forEach((line, i) => textAt(ctx, bodyFont, line, cardX + M.pad + bulletIndent, lineTop + i * bodyLH));
    lineTop += m.height + M.lineGap;
  }

  // Buttons along the bottom, left to right; the first is the primary.
  let bx = cardX + M.pad;
  c.buttonRects = [];
  const btnFont = sysFont(M.bodySize, 600);
  const bm = fontMetrics(btnFont);
  c.buttons.forEach((title, i) => {
    const r: Rect = { x: bx, y: cardY + cardH - M.pad - M.buttonHeight, w: L.btnWs[i], h: M.buttonHeight };
    ctx.fillStyle = i === 0 ? ACCENT[c.kind] : "rgb(230,230,230)";
    ctx.beginPath();
    ctx.roundRect(r.x, r.y, r.w, r.h, M.buttonHeight / 2);
    ctx.fill();
    ctx.fillStyle = i === 0 ? "white" : "rgb(38,38,38)";
    const tw = measure(btnFont, title);
    textAt(ctx, btnFont, title, r.x + r.w / 2 - tw / 2, r.y + r.h / 2 - bm.height / 2);
    c.buttonRects.push(r);
    bx += L.btnWs[i] + M.buttonGap;
  });
  ctx.restore();

  // Hit rect covers the tail too, so a click just under the card still
  // counts rather than falling through to the desktop.
  c.hitRect = { x: cardX, y: bubblesBelow ? cardY - M.tailHeight : cardY, w: cardW, h: cardH + M.tailHeight };
}

// ---------------------------------------------------------------------------
// Puff and steam

/// Chunky pixel-art dust cloud. Particles are integer-aligned filled squares
/// (not soft ellipses) to match the pixel sprite aesthetic.
/// Phases:
///   0% – 54%: avatar is hidden, dust expands from a tight cluster
///   54%: avatar pops in with a spring-back bounce
///   54% – 100%: dust continues outward and fades
function drawPixelPuff(cx: number, cy: number, t: number): void {
  const raw = (t - puffStart) / puffDuration;
  if (raw >= 1) {
    puffActive = false;
    avatarHiddenByPuff = false; // safety
    return;
  }
  const progress = Math.max(0, raw);
  // Ease-out for outward expansion.
  const eased = 1 - Math.pow(1 - progress, 2.5);

  const baseRadius = 4;
  const maxRadius = 104;
  const radius = baseRadius + (maxRadius - baseRadius) * eased;

  // Reveal avatar partway, kick a small spring-back bounce.
  if (avatarHiddenByPuff && progress >= puffRevealAt) {
    avatarHiddenByPuff = false;
    triggerSpringBack();
  }

  // Pixel palette — clean whites for cartoon-dust feel.
  const palette = [255, 245, 219, 189];
  const baseAlpha = Math.max(0, 1 - progress) * 0.95;
  const fill = (i: number, a: number) => { const v = palette[i % palette.length]; ctx.fillStyle = `rgba(${v},${v},${v},${a})`; };

  ctx.save();
  // Outer ring of 14 large pixels, slight angle + radius jitter so it
  // doesn't read as a perfect circle.
  const outerCount = 14;
  for (let i = 0; i < outerCount; i++) {
    const baseAngle = (i / outerCount) * Math.PI * 2;
    const angleJ = ((i * 47) % 11 - 5) * 0.045;
    const angle = baseAngle + angleJ;
    const radJ = ((i * 31) % 9 - 4) * 2.5;
    const r = radius + radJ;
    const pxCenter = cx + Math.cos(angle) * r;
    const pyCenter = cy - Math.sin(angle) * r;
    const size = Math.floor(Math.max(3, 9 - progress * 5)); // 9px → 4px
    fill(i, baseAlpha);
    ctx.fillRect(Math.floor(pxCenter - size / 2), Math.floor(pyCenter - size / 2), size, size);
  }

  // Inner scatter — denser early, sparse late. Deterministic by index so
  // particles stay put frame to frame (no flickering chaos).
  const scatterCount = Math.floor((1 - progress) * 18) + 8;
  for (let i = 0; i < scatterCount; i++) {
    const seedA = ((i * 73) % 360) * Math.PI / 180;
    const seedR = ((i * 53) % 100) / 100.0 * radius * 0.8 + 4;
    const pxCenter = cx + Math.cos(seedA) * seedR;
    const pyCenter = cy - Math.sin(seedA) * seedR;
    const size = i % 4 === 0 ? 6 : 4;
    const alphaJ = ((i * 19) % 100) / 100.0 * 0.5 + 0.5;
    fill(i, baseAlpha * alphaJ);
    ctx.fillRect(Math.floor(pxCenter - size / 2), Math.floor(pyCenter - size / 2), size, size);
  }

  // Bright dense core for the first beat — visually obscures the avatar
  // while it's hidden so the reveal feels like it emerges from the cloud.
  if (progress < 0.35) {
    const coreFade = 1 - progress / 0.35;
    const coreSize = Math.floor(64 * coreFade + 28);
    ctx.fillStyle = `rgba(255,255,255,${coreFade * 0.9})`;
    ctx.fillRect(Math.floor(cx - coreSize / 2), Math.floor(cy - coreSize / 2), coreSize, coreSize);
  }
  ctx.restore();
}

function drawSteam(cx: number, cy: number, t: number): void {
  const steamY = cy - halfChar() + 15;
  ctx.save();
  for (let i = 0; i < 3; i++) {
    const phase = (t * 2.5 + i * 1.1) % 2.2;
    const x = cx + (i - 1) * 14 + Math.sin(t + i) * 6;
    const y = steamY - phase * 25;
    const alpha = (1.0 - phase / 2.2) * 0.7;
    const size = 3 + phase * 4;
    ctx.fillStyle = `rgba(255,255,255,${alpha})`;
    circle(ctx, x, y, size / 2);
  }
  ctx.restore();
}

// ---------------------------------------------------------------------------
// Mouse (NikxelWindow.mouseDown / mouseUp)

function pointFrom(e: MouseEvent): { x: number; y: number } {
  return { x: e.clientX, y: e.clientY };
}

window.addEventListener("mousemove", e => {
  pointer = pointFrom(e);
  // Safety: a release we never heard about (it happened somewhere we don't
  // get events) must not leave Nikxel glued to the cursor.
  if (localDragging && (e.buttons & 1) === 0) endPress();
});

window.addEventListener("mousedown", e => {
  if (e.button !== 0) return;
  const p = pointFrom(e);
  pointer = p;
  // Reminder bubble hit-test takes priority over drag/double-click so a tap
  // on a bubble completes the reminder without engaging the recording toggle.
  const rid = hitTestReminderBubble(p);
  if (rid !== null) {
    dismissReminder(rid);
    post({ type: "reminderTap", id: rid });
    return;
  }
  // Same priority for cards: tapping one opens what it's about instead of
  // picking Nikxel up.
  if (hitTestCard(p) && card) {
    const c = card;
    if (c.buttons.length > 0) {
      // A question: only its buttons answer it.
      const i = cardButton(p);
      if (i === null) return;
      card = null;
      post({ type: "cardButton", id: c.id, index: i });
      return;
    }
    card = null;
    post({ type: "cardTap", id: c.id });
    return;
  }
  // Only engage drag / double-click when the click actually lands on the
  // character. Clicks in the surrounding transparent padding are ignored so
  // they don't accidentally pick Nikxel up.
  if (!hitTestAvatar(p)) return;

  pressOnAvatar = true;
  if (e.detail >= 2) {
    localDragging = false;
    post({ type: "doubleClick" });
    return;
  }
  localDragging = true;
  post({ type: "dragStart" });
});

function endPress(): void {
  if (!pressOnAvatar) return;
  pressOnAvatar = false;
  localDragging = false;
  post({ type: "mouseUp" });
}

window.addEventListener("mouseup", e => { if (e.button === 0) endPress(); });
window.addEventListener("blur", () => { if (localDragging) endPress(); });
// The page must never scroll, select or show a context menu.
window.addEventListener("contextmenu", e => e.preventDefault());
window.addEventListener("dragstart", e => e.preventDefault());

// ---------------------------------------------------------------------------
// Messages from main

let started = false;

function frame(): void {
  tick();
  draw();
  requestAnimationFrame(frame);
}

bridge.onMessage(raw => {
  const m = raw as FromMain;
  switch (m.type) {
    case "init":
      currentState = m.state;
      charSize = 156 * m.avatarSize;
      bubblesBelow = m.bubblesBelow;
      geom = m.geom;
      Promise.all([loadFonts(m.fontBold, m.fontMedium), loadSprites(m.sprite, m.fallback)]).finally(() => {
        if (!started) { started = true; lastTick = now(); requestAnimationFrame(frame); }
        post({ type: "loaded" });
      });
      break;
    case "sprites":
      void loadSprites(m.sprite, m.fallback);
      break;
    case "state":
      currentState = m.state;
      frameIndex = 0;
      frameElapsed = 0;
      if (m.state !== "dragging") dragVelocity = { x: 0, y: 0 };
      break;
    case "size":
      charSize = 156 * m.avatarSize;
      break;
    case "cursor":
      pointer = { x: m.x, y: m.y };
      break;
    case "geom":
      geom = m.geom;
      break;
    case "bubblesBelow":
      bubblesBelow = m.on;
      break;
    case "dragVelocity":
      dragVelocity = { x: m.vx, y: m.vy };
      break;
    case "springBack":
      triggerSpringBack();
      break;
    case "puff":
      triggerPuff();
      break;
    case "key":
      keyTimestamps.push(now());
      break;
    case "card":
      card = { ...m.card, addedAt: now(), opacity: 0, hitRect: ZERO, buttonRects: [], layout: null };
      break;
    case "dismissCard":
      card = null;
      break;
    case "pushReminder":
      pushReminder(m.id, m.title);
      break;
    case "dismissReminder":
      dismissReminder(m.id);
      break;
    case "reminderText":
      reminderText = m.text;
      break;
    case "recording":
      recordingStartedAt = m.startedAt;
      break;
    case "meeting":
      isInMeeting = m.on;
      break;
    case "texter":
      activeTexterName = m.name;
      break;
  }
});

post({ type: "ready" });
