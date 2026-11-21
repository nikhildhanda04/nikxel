/// The avatar's chat box: ask in words or tap the mic. Main builds the context and asks the agent
/// (main/system/avatarChat.ts); this page only keeps the log. Same look and behaviour as src/AvatarChat.swift.

declare global {
  interface Window {
    nikxelChat: {
      send(text: string): Promise<{ text: string; offline: boolean; error: boolean }>;
      voice(pcm: Uint8Array): Promise<string>;
      close(): Promise<void>;
      onRecording(cb: (on: boolean) => void): void;
      hit(rects: number[][]): void;
    };
  }
}

const bridge = window.nikxelChat;

// Tap to talk: MediaRecorder while listening, then decoded at 16 kHz mono
// (decodeAudioData resamples to the context's rate) and sent as PCM.
let recorder: MediaRecorder | null = null, stream: MediaStream | null = null, chunks: Blob[] = [];

const api = {
  send: (t: string) => bridge.send(t),
  close: () => { void bridge.close(); },
  async micStart(): Promise<boolean> {
    try { stream = await navigator.mediaDevices.getUserMedia({ audio: true }); } catch { return false; }
    chunks = [];
    recorder = new MediaRecorder(stream);
    recorder.ondataavailable = e => chunks.push(e.data);
    recorder.start();
    return true;
  },
  async micStop(): Promise<string> {
    const r = recorder;
    if (!r) return "";
    await new Promise<void>(res => { r.onstop = () => res(); r.stop(); });
    recorder = null;
    for (const t of stream?.getTracks() ?? []) t.stop();
    try {
      const ctx = new AudioContext({ sampleRate: 16000 });
      const audio = await ctx.decodeAudioData(await new Blob(chunks).arrayBuffer());
      void ctx.close();
      const f = audio.getChannelData(0), pcm = new Int16Array(f.length);
      for (let i = 0; i < f.length; i++) { const v = Math.max(-1, Math.min(1, f[i])); pcm[i] = v < 0 ? v * 0x8000 : v * 0x7fff; }
      return await bridge.voice(new Uint8Array(pcm.buffer));
    } catch { return ""; }
  },
};

const log = document.getElementById("log")!;
const input = document.getElementById("input") as HTMLInputElement;
const mic = document.getElementById("mic") as HTMLButtonElement;
const send = document.getElementById("send") as HTMLButtonElement;
const placeholder = input.placeholder;
let busy = false, listening = false, meeting = false;

function sync(): void {
  input.disabled = busy || listening;
  mic.disabled = busy || (meeting && !listening);  // a listen already running can still be stopped
  mic.title = meeting ? "Recording — type instead" : "Tap, speak, tap again to send";
  send.disabled = busy || listening || !input.value.trim();
}

function setRecording(on: boolean): void { if (on !== meeting) { meeting = on; sync(); } }

function bubble(cls: string, text: string): HTMLDivElement {
  const d = document.createElement("div");
  d.className = "msg " + cls;
  d.textContent = text;
  log.appendChild(d);
  log.scrollTop = log.scrollHeight;
  return d;
}

function typing(label: string): HTMLDivElement {
  const d = bubble("bot", "");
  d.innerHTML = '<span class="dots"><i></i><i></i><i></i></span>';
  const s = document.createElement("span");
  s.className = "hint";
  s.textContent = label;
  d.appendChild(s);
  return d;
}

function settle(d: HTMLElement, text: string): void {
  d.textContent = text;
  log.scrollTop = log.scrollHeight;
}

async function run(text: string): Promise<void> {
  bubble("me", text);
  const w = typing("thinking…");
  busy = true; sync();
  const r = await api.send(text);
  settle(w, r.text);
  document.getElementById("offline")!.classList.toggle("on", r.offline);
  if (r.error && !input.value) input.value = text;  // keep the question to try again
  busy = false; sync(); input.focus();
}

document.getElementById("f")!.onsubmit = e => {
  e.preventDefault();
  const t = input.value.trim();
  if (!t || busy) return;
  input.value = "";
  void run(t);
};
input.oninput = sync;
// Only the bubbles and the field take clicks; the clear space around them passes through.
function report(): void {
  const L = log.getBoundingClientRect(), r: number[][] = [];
  for (const e of log.querySelectorAll(".msg")) {
    const b = e.getBoundingClientRect(), t = Math.max(b.top, L.top), u = Math.min(b.bottom, L.bottom);
    if (u > t) r.push([b.left, t, b.width, u - t]);
  }
  for (const e of [document.getElementById("f")!, document.getElementById("offline")!]) {
    const b = e.getBoundingClientRect();
    if (b.height) r.push([b.left, b.top, b.width, b.height]);
  }
  bridge.hit(r);
}
new MutationObserver(report).observe(document.body, { childList: true, subtree: true, characterData: true, attributes: true });
log.onscroll = report; window.onresize = report;
if (new URLSearchParams(location.search).get("flip") === "1") document.body.classList.add("flip");
document.addEventListener("keydown", e => { if (e.key === "Escape") api.close(); });

mic.onclick = async () => {
  if (!listening) {
    if (!(await api.micStart())) { bubble("bot", "Couldn't use the microphone."); return; }
    listening = true; mic.classList.add("rec"); input.placeholder = "Listening… tap the mic to send"; sync();
    return;
  }
  listening = false; mic.classList.remove("rec"); input.placeholder = placeholder;
  const w = typing("Listening back…");
  busy = true; sync();
  const text = await api.micStop();
  busy = false; sync();
  if (!text) { settle(w, "Didn't catch that."); return; }
  w.remove();
  void run(text);
};

bubble("bot hello", "Ask me anything from the last two weeks.");
bridge.onRecording(setRecording);
setRecording(new URLSearchParams(location.search).get("rec") === "1");
sync();
input.focus();

export {};
