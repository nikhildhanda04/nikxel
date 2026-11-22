import { BrowserWindow, ipcMain } from "electron";
import * as fs from "fs";
import * as path from "path";
import { cblog } from "../core/diag";
import { documentsRoot, ensureDir, nikxelPath, preloadPath, readText, rendererPath, writeAtomic } from "../core/paths";
import { MOMGenerator } from "../recording/momGenerator";
import { favicon } from "../recording/markdown";
import { NotePage } from "../recording/notePage";
import { Transcriber } from "../recording/transcriber";
import { wavHeader } from "../recording/wavWriter";
import * as Learning from "./learning";

/// Edits a finished summary from a sentence: "Speaker 3 is Rahul", "merge the
/// 2nd and 4th action items". The agent gets the summary's Markdown, the
/// meeting transcript and the instruction, and hands back the whole updated
/// Markdown, which replaces the .md and re-renders the page beside it.
///
/// Meeting and notes pages only. Daily and weekly summaries are editable in
/// the owner's private Mac build alone; there's no such build on Windows.
const backups = () => nikxelPath("edits");
let agent: MOMGenerator | null = null;

const stem = (page: string) => page.slice(0, -path.extname(page).length);

export function editable(page: string): boolean {
  try {
    const root = fs.realpathSync(path.join(documentsRoot(), "nikxel")).toLowerCase();
    const dir = fs.realpathSync(path.dirname(page)).toLowerCase();
    return dir === path.join(root, "meetings") || dir === path.join(root, "notes");
  } catch { return false; }
}

/// The agent's reply: NOTE:/RENAME: lines, "---", then the full Markdown.
/// Null when it isn't a summary (no separator, or no "# " title).
export function parseReply(out: string): { note: string; renames: [string, string][]; markdown: string } | null {
  const split = out.indexOf("\n---\n");
  if (split < 0) return null;
  const markdown = out.slice(split + 5).trim() + "\n";
  if (!markdown.startsWith("# ")) return null;
  let note = "Updated.";
  const renames: [string, string][] = [];
  for (const line of out.slice(0, split).split("\n")) {
    if (line.startsWith("NOTE:")) note = line.slice(5).trim();
    if (line.startsWith("RENAME:")) {
      const parts = line.slice(7).split("=>").map(s => s.trim());
      if (parts.length === 2 && parts[0] && parts[1]) renames.push([parts[0], parts[1]]);
    }
  }
  return { note, renames, markdown };
}

/// Runs the instruction against `page`'s summary. Resolves to the agent's
/// one-line note on what changed.
export async function apply(instruction: string, page: string): Promise<string> {
  const md = stem(page) + ".md", transcriptPath = stem(page) + ".transcript.txt";
  const current = readText(md);
  if (!editable(page) || current === null) throw new Error("This summary can't be edited.");
  const transcript = readText(transcriptPath) ?? "";
  agent ??= new MOMGenerator();
  const reply = parseReply(await agent.runPrompt(prompt(instruction, current, transcript), "summary-edit", "sonnet"));
  if (!reply) throw new Error("The agent's reply wasn't a summary. Nothing changed.");
  if (reply.markdown === current) return reply.note;

  // Every edit keeps what it replaced, so Undo can step back one at a time.
  const dir = ensureDir(path.join(backups(), path.basename(stem(page))));
  const stamp = String(Date.now());
  writeAtomic(path.join(dir, `${stamp}.md`), current);
  if (reply.renames.length && transcript) {
    // Renamed speakers stick in the transcript too, so a regenerate keeps them.
    writeAtomic(path.join(dir, `${stamp}.transcript.txt`), transcript);
    writeAtomic(transcriptPath, reply.renames.reduce((t, [from, to]) => t.replaceAll(from, to), transcript));
  }
  save(reply.markdown, md, page);
  Learning.logEdit(instruction, page);  // repeated fixes can become a standing rule
  return reply.note;
}

/// Puts back the version before the last edit. False when there's none.
export function undo(page: string): boolean {
  const dir = path.join(backups(), path.basename(stem(page)));
  let versions: string[] = [];
  try { versions = fs.readdirSync(dir).filter(f => f.endsWith(".md")).sort(); } catch { /* no edits yet */ }
  const last = versions.at(-1);
  if (!last) return false;
  const prev = path.join(dir, last);
  save(fs.readFileSync(prev, "utf8"), stem(page) + ".md", page);
  const transcript = path.join(dir, last.replace(".md", ".transcript.txt"));
  if (fs.existsSync(transcript)) { try { fs.renameSync(transcript, stem(page) + ".transcript.txt"); } catch { /* keep the page undo */ } }
  fs.rmSync(prev);
  return true;
}

function save(markdown: string, md: string, page: string): void {
  writeAtomic(md, markdown);
  writeAtomic(page, NotePage.html(markdown));
}

function prompt(instruction: string, summary: string, transcript: string): string {
  return `You are editing a summary Nikxel already wrote. Apply the user's instruction to the Markdown below and change nothing else: keep every heading, the section order and the formatting conventions exactly as they are. If the instruction renames a speaker, rename them everywhere in the summary.

Instruction: ${instruction}

Reply in exactly this form and nothing else:
NOTE: <one short sentence on what you changed, or why you couldn't>
RENAME: <speaker label as written> => <new name>   (one line per renamed speaker; leave out if none)
---
<the full updated Markdown, starting with its "# " title line>

If you can't apply the instruction, give the NOTE and the Markdown unchanged.

===== SUMMARY (Markdown) =====
${summary}
${transcript ? `\n===== TRANSCRIPT (for reference only; do not output it) =====\n${transcript.slice(0, 120_000)}` : ""}`;
}

// MARK: - The chat window

/// The small chat window behind a page's Edit button. One per page; type or
/// tap the mic and say it. The page (renderer/editChat.ts) keeps the log.
const open = new Map<string, BrowserWindow>();
let seq = 0;

export function showChat(page: string): void {
  const existing = open.get(page);
  if (existing && !existing.isDestroyed()) { existing.show(); existing.focus(); return; }

  const id = `e${++seq}`;
  const title = (readText(stem(page) + ".md") ?? "").split("\n")[0].replace("# ", "") || path.basename(page);
  const win = new BrowserWindow({
    width: 400,
    height: 540,
    minWidth: 320,
    minHeight: 380,
    minimizable: false,
    maximizable: false,
    alwaysOnTop: true,  // stays up beside the page while you read it
    title: `Edit · ${title}`,
    show: false,
    autoHideMenuBar: true,
    webPreferences: { preload: preloadPath("editChat"), contextIsolation: true, nodeIntegration: false, sandbox: true },
  });
  open.set(page, win);

  ipcMain.handle(`edit:send:${id}`, async (_e, text: string) => {
    let reply: string;
    try { reply = await apply(text, page); } catch (e) { reply = "⚠︎ " + (e as Error).message; }
    cblog(`PageEdit: ${path.basename(page)} — ${reply}`);
    return reply;
  });
  ipcMain.handle(`edit:undo:${id}`, () => {
    let ok = false;
    try { ok = undo(page); } catch { /* reported as nothing to undo */ }
    return ok ? "Undone — the page is back to how it was before the last change." : "Nothing to undo.";
  });
  // 16 kHz mono 16-bit PCM from the page's mic, as whisper.cpp wants it.
  ipcMain.handle(`edit:voice:${id}`, async (_e, pcm: Uint8Array) => {
    const wav = nikxelPath("edits", "voice.wav");
    writeAtomic(wav, Buffer.concat([wavHeader(pcm.byteLength, 16000, 1), Buffer.from(pcm)]));
    try { return (readText(await new Transcriber().transcribe(wav, "txt")) ?? "").trim(); } catch { return ""; }
  });
  win.on("closed", () => {
    for (const ch of ["send", "undo", "voice"]) ipcMain.removeHandler(`edit:${ch}:${id}`);
    if (open.get(page) === win) open.delete(page);
  });
  win.once("ready-to-show", () => { win.show(); win.focus(); });
  const icon = /href="([^"]+)"/.exec(favicon)?.[1] ?? "";
  win.loadFile(rendererPath("editChat"), { query: { id, title, icon } });
}
