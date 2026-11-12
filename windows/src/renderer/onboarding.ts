// The setup wizard page. A view of the state the main process keeps
// (system/onboarding.ts): every state push re-renders the current step, and
// every click goes back as an action. Wording matches OnboardingWindow.swift.

type Step = "welcome" | "avatar" | "deps" | "whatsapp" | "google" | "agent";
type Tone = "secondary" | "red" | "orange" | "green";

interface View {
  step: Step;
  name: string;
  sprites: { cols: number; rows: number; frameSize: number };
  avatar: { frames: string[]; usingCustom: boolean; sheetError: string | null; promptCopied: boolean; importing: boolean };
  deps: {
    whisperFound: boolean; ffmpegFound: boolean; depsChecked: boolean;
    usingWhisperCpp: boolean; modelInstalled: boolean; modelName: string; modelSize: string;
    modelDownloading: boolean; modelProgress: number; modelError: string | null;
    installing: boolean; installMessage: string; installProgress: number | null; installError: string | null;
    language: string; languageOptions: { title: string; code: string }[];
  };
  whatsapp: { connecting: boolean; connected: boolean; launchFailed: string | null };
  google: { connected: boolean; oneClick: boolean };
  agents: { id: string; name: string; status: string; tone: Tone; hint: string | null; copied: boolean; enabled: boolean; chosen: boolean }[];
  agentsTesting: boolean;
}

declare global {
  interface Window {
    onboarding: { onState(cb: (state: View) => void): void; send(action: Record<string, unknown>): void };
  }
}

const api = window.onboarding;
const body = document.getElementById("body")!;
const nav = document.getElementById("nav")!;

let view: View | null = null;
/// What's typed in the name field, kept across re-renders (a state push
/// while typing would otherwise reset it).
let nameDraft: string | null = null;
let previewTimer: number | null = null;
let previewIndex = 0;
let lastStep: Step | null = null;

const send = (type: string, extra: Record<string, unknown> = {}) => api.send({ type, ...extra });

// MARK: - Element helpers

function el<K extends keyof HTMLElementTagNameMap>(tag: K, cls = "", text?: string): HTMLElementTagNameMap[K] {
  const e = document.createElement(tag);
  if (cls) e.className = cls;
  if (text !== undefined) e.textContent = text;
  return e;
}

function label(text: string, opts: { size?: "title" | "small"; secondary?: boolean; bold?: boolean; tone?: Tone } = {}): HTMLElement {
  if (opts.size === "title") return el("h1", "", text);
  const cls = [opts.size === "small" ? "small" : "", opts.secondary ? "secondary" : "", opts.bold ? "bold" : "",
    opts.tone && opts.tone !== "secondary" ? opts.tone : opts.tone === "secondary" ? "secondary" : ""].filter(Boolean).join(" ");
  return el("p", cls, text);
}

function button(title: string, onClick: () => void, opts: { primary?: boolean; disabled?: boolean; mini?: boolean } = {}): HTMLButtonElement {
  const b = el("button", [opts.primary ? "primary" : "", opts.mini ? "mini" : ""].filter(Boolean).join(" "), title);
  b.type = "button";
  b.disabled = !!opts.disabled;
  b.addEventListener("click", onClick);
  return b;
}

function image(src: string | undefined, sizeCls: "s96" | "s112"): HTMLImageElement {
  const img = el("img", `pixel ${sizeCls}`);
  if (src) img.src = src;
  img.alt = "";
  img.draggable = false;
  return img;
}

function spinnerRow(text: string): HTMLElement {
  const row = el("div", "row");
  row.append(el("div", "spinner"), label(text, { size: "small", secondary: true }));
  return row;
}

function progressBar(value: number | null): HTMLProgressElement {
  const bar = el("progress");
  bar.max = 1;
  if (value !== null) bar.value = value;
  return bar;
}

function depRow(name: string, found: boolean, note: string): HTMLElement {
  const row = el("div", "dep");
  row.append(
    el("span", `mark ${found ? "green" : "secondary"}`, found ? "✔" : "✕"),
    el("span", "", name),
    el("span", "secondary", `— ${note}`),
  );
  if (!found) row.append(el("span", "small secondary", "not installed"));
  return row;
}

function spacer(): HTMLElement { return el("div", "spacer"); }

function radio(group: string, title: string, checked: boolean, enabled: boolean, onPick: () => void): HTMLElement {
  const wrap = el("label", `radio${enabled ? "" : " disabled"}`);
  const input = el("input");
  input.type = "radio";
  input.name = group;
  input.checked = checked;
  input.disabled = !enabled;
  input.addEventListener("change", () => { if (input.checked) onPick(); });
  wrap.append(input, el("span", "", title));
  return wrap;
}

// MARK: - Steps

function buildWelcome(v: View): void {
  body.className = "center";
  if (v.avatar.frames[0]) body.append(image(v.avatar.frames[0], "s96"));
  body.append(label("Welcome to Nikxel", { size: "title" }));
  body.append(label("Let's pick your avatar, check the transcription tools, connect WhatsApp auto-replies, and choose which coding agent Nikxel should use — takes about a minute.", { secondary: true }));

  // Meeting summaries label the mic channel with this name. Without it
  // the summary has to call the user something generic, and a wrong
  // name is worse than none.
  body.append(label("What should Nikxel call you in your notes?", { secondary: true }));
  const field = el("input");
  field.type = "text";
  field.placeholder = "Your first name (optional)";
  field.value = nameDraft ?? v.name;
  field.addEventListener("input", () => { nameDraft = field.value; });
  body.append(field);

  nav.append(spacer(), button("Get Started", () => send("welcomeNext", { name: field.value }), { primary: true }));
}

function buildAvatar(v: View): void {
  body.className = "center tight";
  const a = v.avatar, s = v.sprites;
  body.append(label("Your avatar", { size: "title" }));
  const preview = image(a.frames[0], "s112");
  preview.id = "preview";
  body.append(preview);
  body.append(label(a.usingCustom ? "Using your own sprite sheet." : "Using the avatar that ships with Nikxel.", { secondary: true }));
  if (a.sheetError) body.append(label(a.sheetError, { size: "small", tone: "red" }));

  const buttons = el("div", "row");
  buttons.append(button(a.promptCopied ? "Prompt copied ✓" : "Copy Gemini prompt", () => send("copyPrompt")));
  buttons.append(button("Use my own sprite sheet…", () => send("chooseSheet"), { disabled: a.importing }));
  if (a.usingCustom) buttons.append(button("Reset to default", () => send("resetSheet")));
  body.append(buttons);

  if (a.importing) body.append(spinnerRow("Processing sheet…"));

  body.append(label("Paste the prompt into Gemini along with a photo of yourself, then load the PNG it gives you straight back here — Nikxel removes the magenta background and re-frames it for you.", { size: "small", secondary: true }));
  body.append(label(`PNG, ${s.cols} columns x ${s.rows} rows of ${s.frameSize}px frames (${s.cols * s.frameSize}x${s.rows * s.frameSize}). One row per state: idle, typing, thinking, done, dragging, pounce, petted, alert, recording, MOM ready.`, { size: "small", secondary: true }));

  nav.append(button("Back", () => send("go", { step: "welcome" })), spacer(), button("Next", () => send("go", { step: "deps" }), { primary: true }));
}

// Meeting transcription shells out to whisper (speech-to-text) and ffmpeg
// (audio decode). Without them recording produces an audio file and nothing
// else — so surface it during setup instead of letting the first meeting
// fail silently.
function buildDeps(v: View): void {
  body.className = "left";
  const d = v.deps;
  body.append(label("Transcription tools", { size: "title" }));
  body.append(label("Nikxel records meetings, transcribes them with whisper, then has your coding agent write the summary. These two are needed for transcription.", { secondary: true }));
  body.append(depRow("whisper", d.whisperFound, "speech-to-text"));
  body.append(depRow("ffmpeg", d.ffmpegFound, "audio decoding"));

  // whisper.cpp ships no model of its own, so transcription silently can't
  // run until one is downloaded.
  if (d.usingWhisperCpp) {
    body.append(depRow("speech model", d.modelInstalled, "needed by whisper.cpp"));
    if (d.modelDownloading) {
      body.append(progressBar(d.modelProgress));
      body.append(label(`Downloading ${d.modelName}…`, { size: "small", secondary: true }));
    } else if (!d.modelInstalled) {
      body.append(button(`Download speech model (${d.modelSize})`, () => send("downloadModel")));
    }
    if (d.modelError) body.append(label(d.modelError, { size: "small", tone: "red" }));
  }

  body.append(label("Spoken language", { bold: true }));
  body.append(label("Leave this on English unless your meetings are mostly Hindi — English also transcribes Hindi, as Hinglish, and keeps English words spelled correctly.", { size: "small", secondary: true }));
  for (const o of d.languageOptions) {
    body.append(radio("language", o.title, o.code === d.language, true, () => send("pickLanguage", { code: o.code })));
  }

  if (d.depsChecked && !(d.whisperFound && d.ffmpegFound)) {
    if (d.installing) {
      body.append(progressBar(d.installProgress));
      body.append(label(`Installing whisper…${d.installMessage ? ` ${d.installMessage}` : ""} This page updates by itself, and the speech model downloads as soon as whisper is in.`, { size: "small", secondary: true }));
    } else {
      if (!d.whisperFound) {
        body.append(button("Install", () => send("installDeps")));
        body.append(label("Downloads whisper.cpp from GitHub into ~/.nikxel/bin/whisper — no admin rights or terminal needed.", { size: "small", secondary: true }));
      }
      if (d.installError) body.append(label(d.installError, { size: "small", tone: "red" }));
    }
  }
  body.append(button("Re-check", () => send("recheckDeps")));

  const ready = d.whisperFound && d.ffmpegFound && (!d.usingWhisperCpp || d.modelInstalled);
  nav.append(button("Back", () => send("go", { step: "avatar" })), spacer(),
    button(ready ? "Next" : "Skip for now", () => send("go", { step: "whatsapp" }), { primary: true }));
}

function buildWhatsApp(v: View): void {
  body.className = "center";
  const w = v.whatsapp;
  body.append(label("Connect WhatsApp", { size: "title" }));
  body.append(label("Nikxel can reply on your behalf — during meetings, or all day. Click Connect, then scan the QR code in the WhatsApp window that opens.", { secondary: true }));

  if (w.launchFailed) {
    body.append(label(`Couldn't open WhatsApp Web: ${w.launchFailed}`, { secondary: true }));
    body.append(button("Try again", () => send("waConnect")));
  } else if (w.connected) {
    const row = el("div", "row");
    row.append(el("span", "green", "✔"), label("Connected", { tone: "green" }));
    body.append(row);
  } else if (w.connecting) {
    const row = el("div", "row");
    row.append(el("div", "spinner"), label("Waiting for QR scan…", { secondary: true }));
    body.append(row);
  } else {
    body.append(button("Connect WhatsApp", () => send("waConnect")));
  }

  nav.append(button("Back", () => send("go", { step: "deps" })), button("Skip for now", () => send("go", { step: "google" })), spacer());
  if (w.connected) nav.append(button("Next", () => send("go", { step: "google" }), { primary: true }));
}

function buildGoogle(v: View): void {
  body.className = "left";
  const g = v.google;
  body.append(label("Google (optional)", { size: "title" }));
  body.append(label("Connect to get a heads-up before calendar events, and to file a meeting's action items in Google Tasks and follow-ups on your calendar. Nothing is sent without your OK.", { secondary: true }));
  body.append(depRow("Google account", g.connected, g.connected ? "connected" : "not connected"));
  if (!g.connected) {
    body.append(button(g.oneClick ? "Connect Google" : "Connect Google…", () => send("googleConnect")));
    body.append(label(g.oneClick
      ? "Opens your browser to sign in. You can skip this and connect later from the tray menu."
      : "This build needs your own Google client first; the button walks you through it. You can skip and connect later from the tray menu.",
    { size: "small", secondary: true }));
  }
  nav.append(button("Back", () => send("go", { step: "whatsapp" })), spacer(),
    button(g.connected ? "Next" : "Skip for now", () => send("go", { step: "agent" }), { primary: true }));
}

function buildAgent(v: View): void {
  body.className = "left";
  body.append(label("Choose your coding agent", { size: "title" }));
  body.append(label("Nikxel shells out to this to write meeting notes/MOMs and WhatsApp replies.", { secondary: true }));

  for (const a of v.agents) {
    const box = el("div", "agent");
    box.append(radio("agent", a.name, a.chosen, a.enabled, () => send("pickAgent", { agent: a.id })));
    const status = label(a.status, { size: "small", tone: a.tone });
    status.classList.add("status");
    box.append(status);
    if (a.hint) {
      const row = el("div", "row hint");
      row.append(el("code", "", a.hint), button(a.copied ? "Copied ✓" : "Copy", () => send("copyInstall", { agent: a.id }), { mini: true }));
      box.append(row);
    }
    body.append(box);
  }

  body.append(label(v.agentsTesting
    ? "Testing each one with a real request — this takes a few seconds…"
    : "Fix anything marked above in a terminal, then click Test again.", { size: "small", secondary: true }));
  body.append(button("Test again", () => send("recheckAgents"), { disabled: v.agentsTesting }));

  nav.append(button("Back", () => send("go", { step: "google" })), spacer(), button("Finish", () => send("finish"), { primary: true }));
}

// MARK: - Render

/// Animates row 0 (idle) at 3 fps, the same rate the avatar animates it.
function syncPreview(v: View): void {
  const frames = v.step === "avatar" ? v.avatar.frames : [];
  if (frames.length <= 1) {
    if (previewTimer !== null) { clearInterval(previewTimer); previewTimer = null; }
    return;
  }
  if (previewTimer === null) {
    previewIndex = 0;
    previewTimer = window.setInterval(() => {
      const fr = view?.step === "avatar" ? view.avatar.frames : [];
      const img = document.getElementById("preview") as HTMLImageElement | null;
      if (!img || fr.length === 0) return;
      previewIndex = (previewIndex + 1) % fr.length;
      img.src = fr[previewIndex];
    }, 1000 / 3);
  }
  const img = document.getElementById("preview") as HTMLImageElement | null;
  if (img && frames[previewIndex % frames.length]) img.src = frames[previewIndex % frames.length];
}

function render(v: View): void {
  if (v.step !== lastStep) { nameDraft = lastStep === null ? nameDraft : null; lastStep = v.step; }
  const scroll = body.scrollTop;
  const focusedName = document.activeElement instanceof HTMLInputElement && document.activeElement.type === "text";
  body.replaceChildren();
  nav.replaceChildren();
  switch (v.step) {
    case "welcome": buildWelcome(v); break;
    case "avatar": buildAvatar(v); break;
    case "deps": buildDeps(v); break;
    case "whatsapp": buildWhatsApp(v); break;
    case "google": buildGoogle(v); break;
    case "agent": buildAgent(v); break;
  }
  body.scrollTop = scroll;
  if (focusedName || v.step === "welcome") {
    const f = body.querySelector<HTMLInputElement>("input[type=text]");
    if (f && document.activeElement !== f) { f.focus(); f.setSelectionRange(f.value.length, f.value.length); }
  }
  syncPreview(v);
}

api.onState(state => { view = state; render(state); });

// Return presses the step's default button, like keyEquivalent "\r".
document.addEventListener("keydown", e => {
  if (e.key !== "Enter" || e.isComposing) return;
  if (document.activeElement instanceof HTMLButtonElement) return;
  const primary = nav.querySelector<HTMLButtonElement>("button.primary");
  if (primary && !primary.disabled) { e.preventDefault(); primary.click(); }
});

send("ready");

export {};
