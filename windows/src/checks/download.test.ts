import { test } from "node:test";
import * as assert from "node:assert/strict";
import * as fs from "fs";
import * as http from "http";
import * as os from "os";
import * as path from "path";
import { downloadFile } from "../main/recording/transcriber";

/// A cut-off download is resumed from what it got, not started over.
test("download resumes after the connection drops", async () => {
  const body = Buffer.alloc(300_000, 0).map((_, i) => i % 251);
  let requests = 0, ranges: string[] = [];
  const server = http.createServer((req, res) => {
    requests++;
    const range = req.headers.range;
    if (range) {
      ranges.push(range);
      const from = Number(/bytes=(\d+)-/.exec(range)![1]);
      res.writeHead(206, { "Content-Length": body.length - from, "Content-Range": `bytes ${from}-${body.length - 1}/${body.length}` });
      res.end(body.subarray(from));
      return;
    }
    // First try: half the file, then the line drops.
    res.writeHead(200, { "Content-Length": body.length });
    res.write(body.subarray(0, 120_000), () => setTimeout(() => res.destroy(), 50));
  });
  await new Promise<void>(r => server.listen(0, "127.0.0.1", r));
  const url = `http://127.0.0.1:${(server.address() as { port: number }).port}/model.bin`;
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "nx-dl-")), dest = path.join(dir, "model.bin");
  try {
    await assert.rejects(downloadFile(url, dest, () => {}));
    assert.ok(fs.existsSync(dest + ".download") && fs.statSync(dest + ".download").size > 0, "the part is kept");
    await downloadFile(url, dest, () => {});
    assert.deepEqual(fs.readFileSync(dest), body, "whole file, byte for byte");
    assert.equal(requests, 2);
    assert.match(ranges[0], /^bytes=\d+-$/);
    assert.ok(!fs.existsSync(dest + ".download"));
  } finally {
    server.close();
    fs.rmSync(dir, { recursive: true, force: true });
  }
});
