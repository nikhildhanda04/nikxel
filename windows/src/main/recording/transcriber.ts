import * as fs from "fs";
import * as path from "path";
import { once } from "events";
import { ensureDir, HOME, isWin, nikxelPath } from "../core/paths";
import { augmentedEnv, powershell, run, which } from "../core/proc";
import { Settings } from "../core/settings";
import { diag } from "../core/diag";
import { Devanagari } from "../whatsapp/devanagari";

/// Port of Transcriber.swift (+ WhisperModel).
///
/// No Homebrew on Windows: `installWhisper` fetches the official whisper.cpp
/// Windows build from GitHub into ~/.nikxel/bin/whisper/, and the speech model
/// lives in ~/.nikxel/models/ exactly as on the Mac.

export type OutputFormat = "txt" | "srt";

export class TranscriberError extends Error {
  constructor(readonly kind: "binaryNotFound" | "modelMissing" | "failed", message: string) {
    super(message);
    this.name = "TranscriberError";
  }
}

/// Which whisper CLI we found. The two take completely different flags, so
/// passing one's arguments to the other just prints a usage dump -- which is
/// exactly what happened when the setup wizard's install button put
/// whisper.cpp on a machine and the Python flags were sent to it.
///   python: openai-whisper, `whisper file --model base ...`
///   cpp:    whisper.cpp, `whisper-cli -m model.bin -f file -osrt -of stem`
export type Flavor = "python" | "cpp";

export function flavorOf(binary: string): Flavor {
  const name = path.basename(binary).toLowerCase();
  return name.includes("whisper-cli") || name.includes("whisper-cpp") ? "cpp" : "python";
}

/// Where installWhisper unpacks the whisper.cpp release.
export const WHISPER_DIR = path.join(HOME, ".nikxel", "bin", "whisper");

/// 0xC0000135 STATUS_DLL_NOT_FOUND, as Node reports it. The whisper.cpp build
/// links the MSVC runtime, which a fresh Windows install may not have.
const DLL_NOT_FOUND = [3221225781, -1073741515];
const VC_REDIST_URL = "https://aka.ms/vs/17/release/vc_redist.x64.exe";

/// Not /releases/latest: since v1.9.3 the version tags (v1.9.5) carry no
/// files and the binaries go on a build release (b5454) cut the same day.
const WHISPER_RELEASE_API = "https://api.github.com/repos/ggml-org/whisper.cpp/releases?per_page=20";
/// The release asset. Only the plain CPU build: the BLAS/CUDA variants need
/// extra runtimes most machines don't have.
const WHISPER_ASSET = /whisper-bin-x64\.zip/;

/// Depth-limited search for a file name. The release zip has nested its
/// binaries differently across versions (Release/, bin/, flat).
function findFileRecursive(dir: string, name: RegExp, depth: number): string | null {
  let entries: fs.Dirent[];
  try { entries = fs.readdirSync(dir, { withFileTypes: true }); } catch { return null; }
  for (const e of entries) if (e.isFile() && name.test(e.name)) return path.join(dir, e.name);
  if (depth <= 0) return null;
  for (const e of entries) {
    if (!e.isDirectory()) continue;
    const hit = findFileRecursive(path.join(dir, e.name), name, depth - 1);
    if (hit) return hit;
  }
  return null;
}

/// pip installs the Python whisper's launcher into a per-version Scripts
/// folder that is often not on PATH, especially with `pip install --user`.
function pythonWhisperCandidates(): string[] {
  if (!isWin) return [path.join(HOME, ".local", "bin", "whisper")];
  const appData = process.env.APPDATA ?? path.join(HOME, "AppData", "Roaming");
  const local = process.env.LOCALAPPDATA ?? path.join(HOME, "AppData", "Local");
  const out: string[] = [];
  for (let minor = 13; minor >= 9; minor--) {
    out.push(path.join(appData, "Python", `Python3${minor}`, "Scripts", "whisper.exe"));
    out.push(path.join(local, "Programs", "Python", `Python3${minor}`, "Scripts", "whisper.exe"));
  }
  return out;
}

/// Bundled ffmpeg-static, else whatever ffmpeg is on PATH. Inside a packaged
/// app the binary sits in app.asar.unpacked: asar archives can't be executed from.
export function ffmpegPath(): string | null {
  try {
    // eslint-disable-next-line @typescript-eslint/no-var-requires
    let p = require("ffmpeg-static") as string | null;
    if (p) {
      p = p.replace(/app\.asar(?!\.unpacked)/, "app.asar.unpacked");
      if (fs.existsSync(p)) return p;
    }
  } catch { /* not installed */ }
  return which("ffmpeg");
}

// MARK: - Model

/// The ggml model whisper.cpp needs. The release zip ships the binaries
/// without one, so Nikxel keeps its own under ~/.nikxel/models.
export const WhisperModel = {
  get directory(): string { return nikxelPath("models"); },

  /// Small, not base: the base model cannot do Hindi at all -- it transcribes
  /// it into Urdu script even when told -l hi. Small gets it right. Must be a
  /// multilingual build (not a .en variant), which can't do Hindi either.
  defaultName: "ggml-small.bin",
  defaultSourceURL: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.bin",
  defaultDownloadSize: "466 MB",

  /// Bigger models transcribe Hindi noticeably better, so prefer whichever
  /// the user has: dropping a ggml-medium.bin in the folder is all it takes.
  preference: ["ggml-large-v3-turbo.bin", "ggml-large-v3.bin", "ggml-medium.bin", "ggml-small.bin", "ggml-base.bin"],

  installedPath(): string | null {
    const dir = WhisperModel.directory;
    for (const name of WhisperModel.preference) {
      const p = path.join(dir, name);
      try { fs.accessSync(p, fs.constants.R_OK); if (fs.statSync(p).size > 0) return p; } catch { /* next */ }
    }
    // Any other ggml-*.bin the user dropped in, English-only ones last.
    let all: string[];
    try { all = fs.readdirSync(dir); } catch { return null; }
    const candidates = all.filter(n => n.startsWith("ggml-") && n.endsWith(".bin")).sort((a, b) => {
      const ae = a.includes(".en."), be = b.includes(".en.");
      return ae === be ? (a < b ? -1 : a > b ? 1 : 0) : ae ? 1 : -1;
    });
    return candidates.length ? path.join(dir, candidates[0]) : null;
  },

  get isInstalled(): boolean { return WhisperModel.installedPath() !== null; },
};

export function hasModel(): boolean { return WhisperModel.isInstalled; }

/// Where downloadModel puts the default model: ~/.nikxel/models/ggml-small.bin.
export function modelPath(): string { return path.join(WhisperModel.directory, WhisperModel.defaultName); }

/// Streams `url` into `dest` (via a temp file + rename), reporting bytes as
/// they land. Gives up when no data arrives for a minute.
async function downloadFile(url: string, dest: string, onProgress: (got: number, total: number) => void): Promise<void> {
  ensureDir(path.dirname(dest));
  const tmp = `${dest}.download`;
  const ctrl = new AbortController();
  let stall: NodeJS.Timeout | undefined;
  const armStall = () => { if (stall) clearTimeout(stall); stall = setTimeout(() => ctrl.abort(), 60_000); };
  armStall();
  try {
    const res = await fetch(url, { signal: ctrl.signal, redirect: "follow", headers: { "User-Agent": "Nikxel" } });
    if (!res.ok || !res.body) throw new Error(`Download failed: HTTP ${res.status} ${res.statusText}`);
    const total = Number(res.headers.get("content-length") ?? 0);
    const out = fs.createWriteStream(tmp);
    const closed = once(out, "close");
    let got = 0;
    try {
      const reader = res.body.getReader();
      for (;;) {
        const { done, value } = await reader.read();
        if (done) break;
        armStall();
        got += value.byteLength;
        if (!out.write(value)) await once(out, "drain");
        onProgress(got, total);
      }
    } catch (e) {
      out.destroy();
      throw e;
    }
    out.end();
    await closed;
    if (total > 0 && got < total) throw new Error(`Download ended early (${got} of ${total} bytes).`);
    try { fs.rmSync(dest, { force: true }); } catch { /* replaced below anyway */ }
    fs.renameSync(tmp, dest);
  } catch (e) {
    try { fs.rmSync(tmp, { force: true }); } catch { /* ignore */ }
    if (ctrl.signal.aborted) throw new Error("Download stalled: no data for a minute. Check your connection and try again.");
    throw e;
  } finally {
    if (stall) clearTimeout(stall);
  }
}

/// Throttles progress to whole percents so the wizard isn't re-rendered for
/// every 16 KB chunk.
function percentReporter(label: string, progress: (msg: string, frac?: number) => void) {
  let last = -1;
  return (got: number, total: number) => {
    if (total <= 0) {
      const mb = Math.floor(got / 1_048_576);
      if (mb !== last) { last = mb; progress(`${label} ${mb} MB`); }
      return;
    }
    const pct = Math.floor((got / total) * 100);
    if (pct !== last) { last = pct; progress(`${label} ${pct}%`, got / total); }
  };
}

/// Downloads the default model. `progress` gets a message and 0...1.
export async function downloadModel(progress: (msg: string, frac?: number) => void): Promise<void> {
  progress(`Downloading the speech model (${WhisperModel.defaultDownloadSize})…`, 0);
  await downloadFile(WhisperModel.defaultSourceURL, modelPath(), percentReporter("Downloading the speech model…", progress));
  progress("Speech model downloaded.", 1);
}

/// Downloads the latest official whisper.cpp Windows build and unpacks it
/// into ~/.nikxel/bin/whisper/, then checks the binary actually starts.
export async function installWhisper(progress: (msg: string, frac?: number) => void): Promise<void> {
  if (!isWin) throw new Error("Installing whisper.cpp is only automated on Windows.");
  progress("Looking up the latest whisper.cpp release…", 0);
  const res = await fetch(WHISPER_RELEASE_API, {
    headers: { "User-Agent": "Nikxel", Accept: "application/vnd.github+json" },
  });
  if (!res.ok) throw new Error(`Couldn't reach GitHub for whisper.cpp (HTTP ${res.status}).`);
  type Release = { tag_name?: string; assets?: { name: string; browser_download_url: string }[] };
  const releases = (await res.json()) as Release[];
  // Newest first; take the first that actually ships the Windows build.
  let release: Release | undefined, asset: { name: string; browser_download_url: string } | undefined;
  for (const r of releases) {
    const assets = r.assets ?? [];
    asset = assets.find(a => /^whisper-bin-x64\.zip$/i.test(a.name)) ?? assets.find(a => WHISPER_ASSET.test(a.name));
    if (asset) { release = r; break; }
  }
  if (!release || !asset) throw new Error("No recent whisper.cpp release has a Windows x64 build.");
  diag("Transcriber", `installing whisper.cpp ${release.tag_name} from ${asset.browser_download_url}`);

  const binDir = ensureDir(path.dirname(WHISPER_DIR));
  const zip = path.join(binDir, "whisper-bin-x64.zip");
  await downloadFile(asset.browser_download_url, zip, percentReporter("Downloading whisper.cpp…", progress));

  progress("Unpacking whisper.cpp…", 1);
  try { fs.rmSync(WHISPER_DIR, { recursive: true, force: true }); } catch { /* in use? Expand-Archive -Force overwrites */ }
  ensureDir(WHISPER_DIR);
  const q = (s: string) => `'${s.replace(/'/g, "''")}'`;
  const unpack = await powershell(
    `$ErrorActionPreference = 'Stop'; Expand-Archive -LiteralPath ${q(zip)} -DestinationPath ${q(WHISPER_DIR)} -Force`,
    { timeoutMs: 5 * 60_000 });
  try { fs.rmSync(zip, { force: true }); } catch { /* ignore */ }
  if (unpack.code !== 0) {
    throw new Error(`Couldn't unpack whisper.cpp: ${(unpack.stderr || unpack.stdout).trim().slice(0, 300) || `exit ${unpack.code}`}`);
  }

  const bin = findFileRecursive(WHISPER_DIR, /^whisper-cli\.exe$/i, 4);
  if (!bin) throw new Error("whisper.cpp unpacked, but whisper-cli.exe wasn't in it.");
  const probe = await run(bin, ["-h"], { cwd: path.dirname(bin), timeoutMs: 20_000 });
  if (probe.code !== null && DLL_NOT_FOUND.includes(probe.code)) {
    throw new Error(`whisper-cli needs the Microsoft Visual C++ Redistributable. Install it from ${VC_REDIST_URL} and try again.`);
  }
  if (probe.error) throw new Error(`whisper-cli won't start: ${probe.error.message}`);
  progress("whisper.cpp installed.", 1);
}

// MARK: - Transcriber

export class Transcriber {
  /// whisper.cpp from installWhisper first, then PATH (whisper-cli, whisper).
  findBinary(): string | null {
    const bundled = findFileRecursive(WHISPER_DIR, isWin ? /^whisper-cli\.exe$/i : /^whisper-cli$/, 4);
    if (bundled) return bundled;
    return which("whisper-cli") ?? which("whisper-cpp") ?? which("whisper", pythonWhisperCandidates());
  }

  get flavor(): Flavor | null {
    const bin = this.findBinary();
    return bin ? flavorOf(bin) : null;
  }

  /// Resolves to the transcript file (<audio stem>.txt or .srt next to the audio).
  async transcribe(audioPath: string, outputFormat: OutputFormat = "txt"): Promise<string> {
    const bin = this.findBinary();
    if (!bin) {
      throw new TranscriberError("binaryNotFound",
        "Couldn't find whisper. Open Setup → Transcription tools to install it.");
    }
    return this.runWhisper(bin, audioPath, outputFormat);
  }

  /// Rewrites a transcript in Latin letters if whisper returned Devanagari.
  /// Hindi is wanted as Hinglish, not Devanagari, in both the saved
  /// transcript and anything built from it.
  private async romanized(file: string): Promise<string> {
    try {
      const text = await fs.promises.readFile(file, "utf8");
      if (!Devanagari.contains(text)) return file;
      await fs.promises.writeFile(file, Devanagari.romanize(text), "utf8");
    } catch (e) { diag("Transcriber", `romanize failed for ${file}: ${e}`); }
    return file;
  }

  private async runWhisper(binary: string, input: string, format: OutputFormat): Promise<string> {
    const outDir = path.dirname(input);
    const stem = path.basename(input, path.extname(input));
    const txtPath = path.join(outDir, `${stem}.${format}`);
    const altTxtPath = path.join(outDir, `${stem}.wav.${format}`);
    const outStem = path.join(outDir, stem);
    const flavor = flavorOf(binary);
    const lang = Settings.transcriptionLanguage;

    let args: string[];
    if (flavor === "python") {
      args = [input, "--model", "base", "--output_format", format, "--output_dir", outDir, "--fp16", "False"];
      // Python whisper auto-detects when --language is omitted.
      if (lang.toLowerCase() !== "auto") args.push("--language", lang);
    } else {
      // whisper.cpp needs an explicit ggml model -- the release zip ships the
      // binaries without one. Our recordings are already 16 kHz mono WAV, the
      // format it wants. -np keeps stdout to just the transcript.
      const model = WhisperModel.installedPath();
      if (!model) {
        throw new TranscriberError("modelMissing",
          "No speech model in ~/.nikxel/models. Open Setup → Transcription tools to download it.");
      }
      // whisper.cpp defaults to -l en, which would push Hindi and
      // Hinglish speech through English. "auto" detects per recording.
      args = ["-m", model, "-f", input, format === "srt" ? "-osrt" : "-otxt", "-of", outStem, "-l", lang, "-np"];
    }

    // Python whisper shells out to ffmpeg for audio decoding. Without it on
    // PATH it prints "FileNotFoundError: ffmpeg" and exits 0, producing no
    // transcript file, so put the bundled one there.
    const ffmpeg = ffmpegPath();
    let env: NodeJS.ProcessEnv | undefined;
    if (ffmpeg) {
      env = augmentedEnv();
      // Windows spells it "Path"; reuse whichever key is there so the child
      // doesn't get two.
      const key = Object.keys(env).find(k => k.toUpperCase() === "PATH") ?? "PATH";
      env[key] = path.dirname(ffmpeg) + path.delimiter + (env[key] ?? "");
    }

    const r = await run(binary, args, { cwd: path.dirname(binary), env });
    const stdoutLog = path.join(outDir, `${stem}.whisper.stdout.log`);
    const stderrLog = path.join(outDir, `${stem}.whisper.stderr.log`);
    await fs.promises.writeFile(stdoutLog, r.stdout).catch(() => {});
    await fs.promises.writeFile(stderrLog, r.stderr).catch(() => {});

    if (fs.existsSync(txtPath)) return this.romanized(txtPath);
    // whisper.cpp writes <name>.wav.txt when -of is ignored; rename to <name>.txt.
    if (fs.existsSync(altTxtPath)) {
      try { fs.rmSync(txtPath, { force: true }); fs.renameSync(altTxtPath, txtPath); } catch { /* fall through */ }
      return this.romanized(fs.existsSync(txtPath) ? txtPath : altTxtPath);
    }

    let detail: string;
    if (r.code !== null && DLL_NOT_FOUND.includes(r.code)) {
      detail = `whisper couldn't start: the Microsoft Visual C++ Redistributable is missing. Install it from ${VC_REDIST_URL}.`;
    } else {
      const combined = r.stderr ? r.stderr : r.stdout;
      detail = combined ? combined.slice(-600) : `whisper exited ${r.code ?? r.error?.message} but produced no transcript file.`;
    }
    throw new TranscriberError("failed",
      `${detail.trim()}\n\nExpected: ${txtPath}\nBinary: ${binary}\nLogs: ${stderrLog}`);
  }
}
