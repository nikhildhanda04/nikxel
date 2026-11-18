/// A page's Edit chat: type an instruction or tap the mic and say it. Main
/// runs the edit (main/system/pageEdit.ts); this page only keeps the log.
/// Same look and behaviour as the Mac window (src/PageEdit.swift).

declare global {
  interface Window {
    nikxelEdit: { send(text: string): Promise<string>; undo(): Promise<string>; voice(pcm: Uint8Array): Promise<string> };
  }
}

const bridge = window.nikxelEdit;
const query = new URLSearchParams(location.search);
document.getElementById("title")!.textContent = query.get("title") ?? "";
(document.getElementById("icon") as HTMLImageElement).src = query.get("icon") ?? "";

// Tap to talk: MediaRecorder while listening, then decoded at 16 kHz mono
// (decodeAudioData resamples to the context's rate) and sent as PCM.
let recorder: MediaRecorder | null = null, stream: MediaStream | null = null, chunks: Blob[] = [];

const api = {
  send: (t: string) => bridge.send(t),
  undo: () => bridge.undo(),
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
const undoBtn = document.getElementById("undo") as HTMLButtonElement;
let busy = false, recording = false;

function sync(): void {
  input.disabled = undoBtn.disabled = busy || recording;
  mic.disabled = busy;
  send.disabled = busy || recording || !input.value.trim();
}

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

function settle(d: HTMLElement, text: string, ok = false): void {
  d.textContent = text;
  if (ok) d.classList.add("done");
  log.scrollTop = log.scrollHeight;
}

async function run(text: string): Promise<void> {
  bubble("me", text);
  const w = typing("Rewriting the summary…");
  busy = true; sync();
  const reply = await api.send(text);
  settle(w, reply, !reply.startsWith("⚠"));
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
undoBtn.onclick = async () => { bubble("bot", await api.undo()); };

mic.onclick = async () => {
  if (!recording) {
    if (!(await api.micStart())) { bubble("bot", "Couldn't use the microphone."); return; }
    recording = true; mic.classList.add("rec"); input.placeholder = "Listening… tap the mic to send"; sync();
    return;
  }
  recording = false; mic.classList.remove("rec"); input.placeholder = "Tell Nikxel what to change…";
  const w = typing("Listening back…");
  busy = true; sync();
  const text = await api.micStop();
  busy = false; sync();
  if (!text) { settle(w, "I didn't catch that — try again or type it."); return; }
  w.remove();
  void run(text);
};

const hello = bubble("bot", "Hi! Tell me what to change in this summary. Every change can be undone.");
const chips = document.createElement("div");
chips.className = "chips";
for (const [label, fill] of [["Rename a speaker", "Speaker 1 is "], ["Merge two tasks", "Merge action items 1 and 2"], ["Make it shorter", "Make the summary shorter"]]) {
  const b = document.createElement("button");
  b.className = "ghost"; b.type = "button"; b.textContent = label;
  b.onclick = () => { input.value = fill; input.focus(); sync(); };
  chips.appendChild(b);
}
hello.appendChild(chips);
sync();
input.focus();

export {};
