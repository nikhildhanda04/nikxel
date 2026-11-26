// Port of what checks the Mac's Attachments.swift by hand: Word, PDF, text in; images and binaries out.
import { test } from "node:test";
import * as assert from "node:assert/strict";
import * as fs from "fs";
import * as os from "os";
import * as path from "path";
import * as zlib from "zlib";
import * as Att from "../main/system/attachments";

/// A one-file zip, deflated, the way Word writes a .docx.
function zip(name: string, body: string): Buffer {
  const data = zlib.deflateRawSync(Buffer.from(body)), n = Buffer.from(name);
  const local = Buffer.alloc(30); local.writeUInt32LE(0x04034b50, 0); local.writeUInt16LE(8, 8); local.writeUInt32LE(data.length, 18); local.writeUInt16LE(n.length, 26);
  const central = Buffer.alloc(46); central.writeUInt32LE(0x02014b50, 0); central.writeUInt16LE(8, 10); central.writeUInt32LE(data.length, 20); central.writeUInt16LE(n.length, 28);
  const cdStart = 30 + n.length + data.length;
  const end = Buffer.alloc(22); end.writeUInt32LE(0x06054b50, 0); end.writeUInt16LE(1, 8); end.writeUInt16LE(1, 10); end.writeUInt32LE(46 + n.length, 12); end.writeUInt32LE(cdStart, 16);
  return Buffer.concat([local, n, data, central, n, end]);
}

test("Attachments: read Word, PDF and text; refuse images and binaries", () => {
  Att.store.dir = fs.mkdtempSync(path.join(os.tmpdir(), "att-"));
  const docx = zip("word/document.xml", `<w:document><w:body><w:p><w:r><w:t>SOP FORMAT</w:t></w:r></w:p><w:p><w:r><w:t>1. Purpose &amp; scope</w:t></w:r></w:p></w:body></w:document>`);
  const d = Att.add("SOP format.docx", docx);
  assert.ok("id" in d && d.name === "SOP format.docx");
  assert.equal(Att.block((d as { id: string }).id), "### a file the user attached: SOP format.docx\nSOP FORMAT\n1. Purpose & scope");

  const content = zlib.deflateSync(Buffer.from("BT /F1 12 Tf 72 700 Td (Client SOP) Tj 0 -14 Td [(Owner: ) -20 (Vikas)] TJ ET"));
  const pdf = Buffer.concat([Buffer.from("%PDF-1.4\n4 0 obj << /Filter /FlateDecode >> stream\n"), content, Buffer.from("\nendstream endobj\n%%EOF")]);
  const p = Att.add("sop.pdf", pdf);
  assert.ok("id" in p); assert.match(Att.block((p as { id: string }).id) ?? "", /Client SOP\nOwner: Vikas/);

  const t = Att.add("notes.md", Buffer.from("# Steps\n- confirm scope"));
  assert.ok("id" in t && t.chars === 23);
  assert.match(("error" in Att.add("photo.png", Buffer.from([0x89, 0x50]))) ? "refused" : "", /refused/, "images are refused on Windows");
  assert.ok("error" in Att.add("blob.bin", Buffer.from([1, 0, 2])), "binary refused");
  assert.equal(Att.block("../../etc"), null, "only our ids");
  assert.equal(fs.readdirSync(Att.store.dir).length, 3, "refused files aren't kept");
  fs.rmSync(Att.store.dir, { recursive: true, force: true });
});
