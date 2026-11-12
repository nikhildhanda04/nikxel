import * as fs from "fs";
import * as os from "os";
import * as path from "path";
import { BrowserWindow } from "electron";
import { NoteFormat, NOTE_FORMAT_INFO } from "../core/settings";
import { markdownToHtml } from "./markdown";
import { markdownToDocx } from "./docx";
import { NotePage } from "./notePage";

/// Port of NoteExporter.swift.
///
/// Writes a generated note out as a page, PDF or Word alongside the Markdown the agent
/// produced, so the file can be shared with people who don't want a .md.
///
/// No new dependencies: Markdown becomes HTML here; Chromium prints that to
/// PDF (an offscreen window + printToPDF, standing in for CoreText), and the
/// .docx is written directly by docx.ts (standing in for AppKit's exporter).

export class ExportError extends Error {
  constructor(message = "Couldn't render the note into that format.") { super(message); this.name = "ExportError"; }
}

export const NoteExporter = {
  /// Converts `markdown` and writes it next to `markdownPath` with the right
  /// extension. Resolves to the new file, or the original for "markdown".
  async export(markdown: string, markdownPath: string, format: NoteFormat): Promise<string> {
    if (format === "markdown") return markdownPath;
    const dir = path.dirname(markdownPath);
    const stem = path.basename(markdownPath, path.extname(markdownPath));
    const destination = path.join(dir, `${stem}.${NOTE_FORMAT_INFO[format].ext}`);
    switch (format) {
      case "page":
        await fs.promises.writeFile(destination, NotePage.html(markdown), "utf8");
        break;
      case "word":
        await fs.promises.writeFile(destination, markdownToDocx(markdown));
        break;
      case "pdf":
        await fs.promises.writeFile(destination, await renderPDF(markdownToHtml(markdown, stem)));
        break;
    }
    return destination;
  },

  html(markdown: string): string { return markdownToHtml(markdown); },
};

/// Prints the HTML from a hidden, script-less window. The page goes through a
/// temp file rather than a data: URL, which Chromium caps at 2 MB.
async function renderPDF(html: string): Promise<Buffer> {
  const tmp = path.join(os.tmpdir(), `nikxel-note-${process.pid}-${Date.now()}.html`);
  await fs.promises.writeFile(tmp, html, "utf8");
  const win = new BrowserWindow({
    show: false,
    width: 816,
    height: 1056,
    webPreferences: { javascript: false, sandbox: true, contextIsolation: true, nodeIntegration: false },
  });
  try {
    await win.loadFile(tmp);
    // US Letter with a 0.75" margin, as the Mac build laid it out.
    return await win.webContents.printToPDF({
      pageSize: "Letter",
      margins: { top: 0.75, bottom: 0.75, left: 0.75, right: 0.75 },
      printBackground: true,
      generateDocumentOutline: true,
    });
  } catch (e) {
    throw new ExportError(`Couldn't render the note into that format: ${(e as Error).message}`);
  } finally {
    if (!win.isDestroyed()) win.destroy();
    fs.promises.rm(tmp, { force: true }).catch(() => {});
  }
}
