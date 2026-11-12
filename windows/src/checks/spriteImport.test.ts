// Smoke-checks the sprite importer's pixel pipeline (port of
// check_sprite_import.sh): a magenta-backed sheet at a deliberately wrong
// size comes back as a clean 256x640 sheet with art in the top and bottom
// rows, and a sheet with the wrong number of rows is refused with the count
// it found. Synthetic sheets, so it needs neither Pillow nor Electron.
import { test } from "node:test";
import * as assert from "node:assert/strict";
import { Bitmap, processBitmap } from "../main/system/spriteSheetImporter";

/// A w x h magenta sheet with `rows` x `cols` coloured figures on it.
function sheet(w: number, h: number, rows: number, cols: number): Bitmap {
  const b = new Bitmap(w, h);
  for (let i = 0; i < b.px.length; i += 4) { b.px[i] = 255; b.px[i + 1] = 0; b.px[i + 2] = 255; b.px[i + 3] = 255; }
  const cw = w / cols, ch = h / rows;
  for (let r = 0; r < rows; r++) {
    for (let c = 0; c < cols; c++) {
      // A figure filling the middle 60% of its cell, in a non-magenta colour.
      for (let y = Math.floor(r * ch + ch * 0.2); y < Math.floor(r * ch + ch * 0.8); y++) {
        for (let x = Math.floor(c * cw + cw * 0.2); x < Math.floor(c * cw + cw * 0.8); x++) {
          const i = b.idx(x, y);
          b.px[i] = 40 + r * 10; b.px[i + 1] = 120; b.px[i + 2] = 60 + c * 20; b.px[i + 3] = 255;
        }
      }
    }
  }
  return b;
}

test("a wrong-size magenta sheet becomes a clean 256x640 sheet", async () => {
  const out = await processBitmap(sheet(1024, 1000, 10, 4));
  assert.equal(out.w, 256);
  assert.equal(out.h, 640);
  for (let y = 0; y < out.h; y++) {
    for (let x = 0; x < out.w; x++) {
      const i = out.idx(x, y);
      const [r, g, b, a] = [out.px[i], out.px[i + 1], out.px[i + 2], out.px[i + 3]];
      assert.ok(!(a > 128 && r > 150 && g < 100 && b > 150), `magenta survived at ${x},${y}`);
      assert.ok(a === 0 || a === 255, `partial alpha at ${x},${y}`);
    }
  }
  const opaque = (top: number) => {
    let n = 0;
    for (let y = top; y < top + 64; y++) for (let x = 0; x < 256; x++) if (out.alpha(x, y) > 0) n++;
    return n;
  };
  assert.ok(opaque(0) > 500, "idle row is empty");
  assert.ok(opaque(576) > 500, "last row is empty");
});

test("a sheet with the wrong number of rows is refused", async () => {
  await assert.rejects(processBitmap(sheet(512, 900, 9, 4)), /reads as 9 rows x 4 poses, but Nikxel needs 10 x 4/);
});

test("a tiny image is refused", async () => {
  await assert.rejects(processBitmap(new Bitmap(3, 3)), /too small/);
});
