/// About Me: type or talk to tell Nikxel who you are. Main stores it
/// (main/system/aboutMe.ts) and feeds it into every prompt. Same voice path as
/// the Edit chat; same look as src/AboutMe.swift.

declare global {
  interface Window {
    nikxelAbout: { load(): Promise<string>; save(text: string): Promise<string>; voice(pcm: Uint8Array): Promise<string> };
  }
}

const bridge = window.nikxelAbout;
const t = document.getElementById("t") as HTMLTextAreaElement;
const mic = document.getElementById("mic") as HTMLButtonElement;
const save = document.getElementById("save") as HTMLButtonElement;
const msg = document.getElementById("msg")!;
function say(s: string): void { msg.textContent = s; }

let recorder: MediaRecorder | null = null, stream: MediaStream | null = null, chunks: Blob[] = [];
let recording = false, busy = false;

async function micStart(): Promise<boolean> {
  try { stream = await navigator.mediaDevices.getUserMedia({ audio: true }); } catch { return false; }
  chunks = [];
  recorder = new MediaRecorder(stream);
  recorder.ondataavailable = e => chunks.push(e.data);
  recorder.start();
  return true;
}

async function micStop(): Promise<string> {
  const r = recorder;
  if (!r) return "";
  await new Promise<void>(res => { r.onstop = () => res(); r.stop(); });
  recorder = null;
  for (const tr of stream?.getTracks() ?? []) tr.stop();
  try {
    const ctx = new AudioContext({ sampleRate: 16000 });
    const audio = await ctx.decodeAudioData(await new Blob(chunks).arrayBuffer());
    void ctx.close();
    const f = audio.getChannelData(0), pcm = new Int16Array(f.length);
    for (let i = 0; i < f.length; i++) { const v = Math.max(-1, Math.min(1, f[i])); pcm[i] = v < 0 ? v * 0x8000 : v * 0x7fff; }
    return await bridge.voice(new Uint8Array(pcm.buffer));
  } catch { return ""; }
}

mic.onclick = async () => {
  if (busy) return;
  if (!recording) {
    if (!(await micStart())) { say("Couldn't use the microphone."); return; }
    recording = true; mic.classList.add("rec"); mic.textContent = "● Stop"; say("Listening…");
    return;
  }
  recording = false; mic.classList.remove("rec"); mic.textContent = "🎤 Talk"; busy = true; say("Typing it in…");
  const heard = await micStop();
  busy = false; say("");
  if (heard) { t.value = (t.value.trim() ? t.value.trim() + " " : "") + heard; t.focus(); }
  else say("I didn't catch that — try again or type it.");
};

save.onclick = async () => { save.disabled = true; await bridge.save(t.value); say("Saved ✓"); save.disabled = false; };

void bridge.load().then(c => { t.value = c || ""; t.focus(); });

export {};
