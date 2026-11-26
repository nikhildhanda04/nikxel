import * as crypto from "crypto";
import * as fs from "fs";
import * as path from "path";
import * as zlib from "zlib";
import { cblog } from "../core/diag";
import { ensureDir, nikxelPath, readText } from "../core/paths";

/// Files the user hands Nikxel: dropped on (or + in) the chat, or attached to an automation, like
/// the SOP format to follow after every client meeting. Each is kept in ~/.nikxel/files/<id>/ with
/// the text read out of it (.text), which is all the chat and automations ever see: Word, ODT, PDF
/// and text files. Never uploaded. Port of src/Attachments.swift.
/// ponytail: no OCR here (the Mac reads images on-device); Windows.Media.Ocr if images matter on Windows.

/// Settable so checks can point it at a temp folder.
export const store = { dir: nikxelPath("files") };
const CAP = 40_000;          // characters of one file a prompt gets
const MAX_BYTES = 15_000_000;
const IMAGES = new Set(["png", "jpg", "jpeg", "heic", "gif", "tif", "tiff", "bmp", "webp"]);
const isId = (id: string) => /^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$/i.test(id);

/// Saves a file and reads its text: {id, name, chars}, or {error} to show.
export function add(name: string, data: Buffer): { id: string; name: string; chars: number } | { error: string } {
  if (data.length > MAX_BYTES) return { error: `${name} is over 15 MB.` };
  const safe = path.basename(name.replace(/\\/g, "/")).replace(/^\.+/, "").slice(0, 120) || "file";
  const id = crypto.randomUUID().toUpperCase(), folder = path.join(store.dir, id), file = path.join(folder, safe);
  try { ensureDir(folder); fs.writeFileSync(file, data); } catch { return { error: `Couldn’t save ${name}.` }; }
  const ext = path.extname(safe).slice(1).toLowerCase();
  if (IMAGES.has(ext)) {
    fs.rmSync(folder, { recursive: true, force: true });
    return { error: `I can’t read the words in images on Windows yet. Attach ${safe} as a PDF or Word file instead.` };
  }
  let text = "";
  try { text = extract(file, data).trim().slice(0, CAP); } catch { text = ""; }
  if (!text) {
    fs.rmSync(folder, { recursive: true, force: true });
    return { error: `I couldn’t read any text in ${safe}. Try a PDF, Word or text file.` };
  }
  fs.writeFileSync(path.join(folder, ".text"), text);
  cblog(`Attachments: read ${text.length} chars from a .${ext} file`);
  return { id, name: safe, chars: text.length };
}

export function addFile(file: string): ReturnType<typeof add> {
  try { return add(path.basename(file), fs.readFileSync(file)); } catch { return { error: `Couldn’t open ${path.basename(file)}.` }; }
}

export function extract(file: string, data: Buffer): string {
  const ext = path.extname(file).slice(1).toLowerCase();
  if (ext === "docx") return xmlText(unzipEntry(data, "word/document.xml"));
  if (ext === "odt") return xmlText(unzipEntry(data, "content.xml"));
  if (ext === "pdf") return pdfText(data);
  if (data.includes(0)) return ""; // a binary file we can't read, not text
  const raw = data.toString("utf8");
  return ext === "html" || ext === "htm" ? raw.replace(/<(script|style)[\s\S]*?<\/\1>|<[^>]+>/g, " ") : raw;
}

/// One stored file out of a zip (docx, odt), or null.
export function unzipEntry(buf: Buffer, want: string): Buffer | null {
  const eocd = buf.lastIndexOf(Buffer.from([0x50, 0x4b, 0x05, 0x06]));
  if (eocd < 0) return null;
  let p = buf.readUInt32LE(eocd + 16);
  for (let i = buf.readUInt16LE(eocd + 10); i > 0; i--) {
    if (buf.readUInt32LE(p) !== 0x02014b50) return null;
    const method = buf.readUInt16LE(p + 10), size = buf.readUInt32LE(p + 20), nameLen = buf.readUInt16LE(p + 28);
    const extra = buf.readUInt16LE(p + 30), comment = buf.readUInt16LE(p + 32), local = buf.readUInt32LE(p + 42);
    if (buf.toString("utf8", p + 46, p + 46 + nameLen) === want) {
      const start = local + 30 + buf.readUInt16LE(local + 26) + buf.readUInt16LE(local + 28);
      const data = buf.subarray(start, start + size);
      return method === 8 ? zlib.inflateRawSync(data) : method === 0 ? data : null;
    }
    p += 46 + nameLen + extra + comment;
  }
  return null;
}

/// A Word or ODT body's words: paragraphs on their own lines.
function xmlText(xml: Buffer | null): string {
  if (!xml) return "";
  return xml.toString("utf8")
    .replace(/<w:tab\/>|<text:tab\/>/g, "\t").replace(/<\/w:p>|<\/text:p>|<\/text:h>|<w:br\/>/g, "\n")
    .replace(/<[^>]+>/g, "")
    .replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&quot;/g, "\"").replace(/&apos;/g, "'").replace(/&amp;/g, "&");
}

/// The text a PDF draws: every (string) Tj and [array] TJ in its (inflated) content streams.
/// ponytail: fonts with custom encodings (CID, Identity-H) come out empty and the user is asked for a Word file; pdf.js if that bites.
export function pdfText(buf: Buffer): string {
  const out: string[] = [];
  const bin = buf.toString("latin1");
  const re = /stream\r?\n/g;
  let m: RegExpExecArray | null;
  while ((m = re.exec(bin))) {
    const start = m.index + m[0].length, end = bin.indexOf("endstream", start);
    if (end < 0) break;
    const raw = buf.subarray(start, end);
    let content: string;
    try { content = zlib.inflateSync(raw).toString("latin1"); } catch { content = raw.toString("latin1"); }
    if (!/T[Jj*]/.test(content)) continue;
    // Strings inside BT…ET; a line break on T*, ', " and moves that change the line.
    for (const op of content.matchAll(/\((?:\\.|[^\\)])*\)\s*Tj|\[(?:\\.|[^\]\\])*\]\s*TJ|T\*|-?[\d.]+\s+(-?[\d.]+)\s+T[dD]|ET/g)) {
      const s = op[0];
      if (s === "T*" || s === "ET" || (op[1] !== undefined && Number(op[1]) !== 0)) { out.push("\n"); continue; }
      if (op[1] !== undefined) continue;
      for (const str of s.matchAll(/\(((?:\\.|[^\\)])*)\)/g)) out.push(unescapePdf(str[1]));
    }
  }
  const text = out.join("").replace(/[ \t]*\n[\s\n]*/g, "\n");
  // Mostly unprintable: a font we can't map, so nothing useful.
  const printable = text.replace(/[^\x20-\x7e\n -ÿ]/g, "").length;
  return printable < text.length * 0.8 ? "" : text;
}

function unescapePdf(s: string): string {
  return s.replace(/\\([nrtbf()\\]|[0-7]{1,3})/g, (_, c: string) =>
    /^[0-7]/.test(c) ? String.fromCharCode(parseInt(c, 8)) : ({ n: "\n", r: "\r", t: "\t", b: "\b", f: "\f" } as Record<string, string>)[c] ?? c);
}

/// The file's name, null when it's gone (or `id` isn't one of ours).
export function name(id: string): string | null {
  if (!isId(id)) return null;
  try { return fs.readdirSync(path.join(store.dir, id)).find(f => !f.startsWith(".")) ?? null; } catch { return null; }
}

/// One file as a prompt block, null when it's gone.
export function block(id: string, heading = "a file the user attached"): string | null {
  const n = name(id), text = n ? readText(path.join(store.dir, id, ".text")) : null;
  return n && text !== null ? `### ${heading}: ${n}\n${text}` : null;
}
