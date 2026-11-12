import { nativeImage } from "electron";
import { Sprites } from "../core/settings";

/// Turns a raw sprite sheet -- including the magenta-backed one the bundled
/// Gemini prompt produces -- into the 256x640 transparent sheet the avatar
/// renderer expects. This is a port of remove_magenta.py so the setup
/// wizard's "Your avatar" step can accept whatever Gemini hands back without
/// the user having to run Python (and install Pillow) first.
///
/// Pixels come from Electron's nativeImage. `toBitmap()` is in the platform's
/// native order -- BGRA on Windows -- and nothing here needs to convert it:
/// every test below is symmetric in red and blue (magenta is R≈B, the halo
/// check adds them, the outline is white), so the buffer is processed and
/// written back in whatever order it came.

export class SpriteImportError extends Error {
  constructor(message: string) { super(message); this.name = "SpriteImportError"; }
}

const f = Sprites.frameSize;   // 64
const cols = Sprites.cols;     // 4
const rows = Sprites.rows;     // 10
const sheetW = cols * f;       // 256
const sheetH = rows * f;       // 640

export const ImportErrors = {
  unreadable: () => new SpriteImportError("Couldn't read that PNG."),
  tooSmall: () => new SpriteImportError(`That image is too small to slice into ${cols}x${rows} frames.`),
  empty: () => new SpriteImportError("That sheet came out empty -- every frame was background. Is it the right image?"),
  wrongGrid: (r: number, c: number) => new SpriteImportError(
    `That sheet reads as ${r} rows x ${c} poses, but Nikxel needs ${rows} x ${cols}. Gemini often ignores the grid -- ask it again for ${rows} rows of ${cols} frames, with a clear magenta gap between rows.`),
};

/// A plain top-left-origin 4-bytes-per-pixel buffer, alpha last.
export class Bitmap {
  readonly px: Uint8Array;
  constructor(readonly w: number, readonly h: number, px?: Uint8Array) {
    this.px = px ?? new Uint8Array(w * h * 4);
  }
  idx(x: number, y: number): number { return (y * this.w + x) * 4; }
  alpha(x: number, y: number): number { return this.px[(y * this.w + x) * 4 + 3]; }
  clear(x: number, y: number): void { this.px.fill(0, this.idx(x, y), this.idx(x, y) + 4); }
  clone(): Bitmap { return new Bitmap(this.w, this.h, this.px.slice()); }
}

type Band = { start: number; end: number };

const tick = () => new Promise<void>(r => setImmediate(r));

/// Keys out the magenta, finds the real grid, and lays every pose out on the
/// 256x640 grid the renderer expects. Pure, so the checks can run it under
/// plain Node. Yields between the passes over the full-size image so a big
/// sheet doesn't freeze the main process for its whole run.
export async function processBitmap(src: Bitmap): Promise<Bitmap> {
  if (src.w < cols || src.h < rows) throw ImportErrors.tooSmall();
  keyOutMagenta(src);
  await tick();

  // Find the grid instead of assuming the image divides evenly into it.
  // Gemini's sheets routinely don't: one real example was 1312x3264, and
  // 3264/10 isn't whole, so slicing at fixed 64px boundaries cut straight
  // through every character -- which is exactly what made the avatar look
  // mangled as it changed state.
  const rowBands = grid(src, true, rows);
  await tick();
  const colBands = grid(src, false, cols);
  if (rowBands.length !== rows || colBands.length !== cols) {
    throw ImportErrors.wrongGrid(rowBands.length, colBands.length);
  }

  // One scale for the whole sheet, sized so the tallest row band and the
  // widest column band both fit with room for the outline. Scaling each
  // pose to its own fixed height is what made the avatar pop between
  // states, so every cell shares this factor.
  const tallest = Math.max(1, ...rowBands.map(b => b.end - b.start + 1));
  const widest = Math.max(1, ...colBands.map(b => b.end - b.start + 1));
  const scale = Math.min(1.0, (f - 4) / Math.max(tallest, widest));

  const out = new Bitmap(sheetW, sheetH);
  rowBands.forEach((rowBand, r) => {
    colBands.forEach((colBand, c) => {
      const cell = sampleCell(src, colBand.start, rowBand.start,
        colBand.end - colBand.start + 1, rowBand.end - rowBand.start + 1, scale);
      blit(cell, out, c * f, r * f);
    });
  });

  let any = false;
  for (let i = 3; i < out.px.length; i += 4) if (out.px[i] > 0) { any = true; break; }
  if (!any) throw ImportErrors.empty();

  for (let i = 0; i < 3; i++) cleanMagentaFringe(out);
  hardenEdges(out);
  addOutline(out);
  return out;
}

/// The sheet's real row (or column) boundaries: runs of lines holding
/// artwork, separated by background. Where two rows touch -- a jump pose
/// reaching into the row above, say -- the runs merge, so oversized bands
/// are split back apart at their emptiest line until the count matches.
function grid(bmp: Bitmap, horizontal: boolean, expected: number): Band[] {
  const outer = horizontal ? bmp.h : bmp.w;
  const inner = horizontal ? bmp.w : bmp.h;
  // A couple of stray pixels left by the chroma key shouldn't glue two
  // bands together, so a line needs real content to count as occupied.
  const threshold = Math.max(1, Math.floor(inner / 100));

  const occupancy = new Array<number>(outer).fill(0);
  for (let i = 0; i < outer; i++) {
    let count = 0;
    for (let j = 0; j < inner; j++) {
      const a = horizontal ? bmp.alpha(j, i) : bmp.alpha(i, j);
      if (a > 30) count++;
    }
    occupancy[i] = count;
  }

  const result: Band[] = [];
  let start: number | null = null;
  for (let i = 0; i < outer; i++) {
    if (occupancy[i] > threshold) {
      if (start === null) start = i;
    } else if (start !== null) {
      result.push({ start, end: i - 1 }); start = null;
    }
  }
  if (start !== null) result.push({ start, end: outer - 1 });

  let attempts = 0;
  while (result.length < expected && attempts < expected * 2) {
    attempts++;
    const i = tallestBand(result);
    if (i === null || result[i].end - result[i].start < 3) break;
    const { start: bandStart, end: bandEnd } = result[i];
    // Split in the middle half -- the seam between two merged poses is
    // in there, and the band's own edges obviously are not.
    const quarter = Math.trunc((bandEnd - bandStart) / 4);
    const low = bandStart + quarter, high = bandEnd - quarter;
    if (!(high > low)) break;
    let seam = low;
    for (let line = low; line <= high; line++) if (occupancy[line] < occupancy[seam]) seam = line;
    // Only split where the seam is near-empty. A sheet with the wrong
    // number of rows has no seam to find, so its emptiest middle line
    // still runs through artwork -- splitting there would manufacture
    // the right band count out of sliced characters and hide the real
    // problem. Measured: a genuine touch-seam sits around 8% of the
    // width, a cut through four characters around 32%.
    if (!(occupancy[seam] * 100 < inner * 15)) break;
    result.splice(i, 1, { start: bandStart, end: seam - 1 }, { start: seam + 1, end: bandEnd });
  }
  return result;
}

function tallestBand(bands: Band[]): number | null {
  if (bands.length === 0) return null;
  let best = 0;
  bands.forEach((b, i) => { if (b.end - b.start > bands[best].end - bands[best].start) best = i; });
  return best;
}

/// Copies one source rect into a 64x64 cell, scaled and centred. The rect
/// comes from the detected grid, so each pose keeps its position and size
/// relative to the others.
function sampleCell(src: Bitmap, x: number, y: number, w: number, h: number, scale: number): Bitmap {
  const cell = new Bitmap(f, f);
  const dw = w * scale, dh = h * scale;
  const offX = (f - dw) / 2, offY = (f - dh) / 2;
  for (let dy = 0; dy < f; dy++) {
    const sy = Math.floor((dy + 0.5 - offY) / scale);
    if (sy < 0 || sy >= h) continue;
    for (let dx = 0; dx < f; dx++) {
      const sx = Math.floor((dx + 0.5 - offX) / scale);
      if (sx < 0 || sx >= w) continue;
      const s = src.idx(x + sx, y + sy), d = cell.idx(dx, dy);
      if (src.px[s + 3] === 0) continue;
      cell.px[d] = src.px[s];
      cell.px[d + 1] = src.px[s + 1];
      cell.px[d + 2] = src.px[s + 2];
      cell.px[d + 3] = src.px[s + 3];
    }
  }
  return cell;
}

// MARK: - Pixel passes (mirrors remove_magenta.py)

/// Chroma key: #FF00FF-ish (R>150, G<100, B>150) becomes transparent,
/// everything else becomes fully opaque.
function keyOutMagenta(bmp: Bitmap): void {
  const p = bmp.px;
  for (let i = 0; i < p.length; i += 4) {
    if (p[i + 3] < 30) { p[i] = p[i + 1] = p[i + 2] = p[i + 3] = 0; continue; }
    if (p[i] > 150 && p[i + 1] < 100 && p[i + 2] > 150) {
      p[i] = p[i + 1] = p[i + 2] = p[i + 3] = 0;
    } else {
      p[i + 3] = 255;
    }
  }
}

/// Scrubs the magenta-tinted halo the key leaves behind: a pinkish pixel
/// with 2+ transparent neighbours was background bleed, not art.
function cleanMagentaFringe(bmp: Bitmap): void {
  const snapshot = bmp.clone();
  for (let y = 0; y < bmp.h; y++) {
    for (let x = 0; x < bmp.w; x++) {
      const i = snapshot.idx(x, y);
      if (snapshot.px[i + 3] < 200) continue;
      const r = snapshot.px[i], g = snapshot.px[i + 1], b = snapshot.px[i + 2];
      if (!(r > 100 && b > 100 && g / Math.max(r + b, 1) < 0.4)) continue;
      let transparentNeighbours = 0;
      for (let dy = -1; dy <= 1; dy++) {
        for (let dx = -1; dx <= 1; dx++) {
          const nx = x + dx, ny = y + dy;
          if (nx < 0 || nx >= snapshot.w || ny < 0 || ny >= snapshot.h) continue;
          if (snapshot.alpha(nx, ny) < 30) transparentNeighbours++;
        }
      }
      if (transparentNeighbours >= 2) bmp.clear(x, y);
    }
  }
}

/// No partial alpha in the final sheet -- a semi-transparent pixel either
/// touches solid art (snap opaque) or is leftover fringe (snap clear).
function hardenEdges(bmp: Bitmap): void {
  const snapshot = bmp.clone();
  for (let y = 0; y < bmp.h; y++) {
    for (let x = 0; x < bmp.w; x++) {
      const a = snapshot.alpha(x, y);
      if (!(a > 0 && a < 200)) continue;
      let touchesSolid = false;
      for (let dy = -1; dy <= 1; dy++) {
        for (let dx = -1; dx <= 1; dx++) {
          const nx = x + dx, ny = y + dy;
          if (nx < 0 || nx >= snapshot.w || ny < 0 || ny >= snapshot.h) continue;
          if (snapshot.alpha(nx, ny) > 200) touchesSolid = true;
        }
      }
      if (touchesSolid) bmp.px[bmp.idx(x, y) + 3] = 255; else bmp.clear(x, y);
    }
  }
}

/// 1px white halo -- what keeps the avatar readable over any wallpaper.
function addOutline(cell: Bitmap): void {
  const snapshot = cell.clone();
  for (let y = 0; y < cell.h; y++) {
    for (let x = 0; x < cell.w; x++) {
      if (snapshot.alpha(x, y) > 100) continue;
      let nearArt = false;
      for (let dy = -1; dy <= 1; dy++) {
        for (let dx = -1; dx <= 1; dx++) {
          const nx = x + dx, ny = y + dy;
          if (nx < 0 || nx >= snapshot.w || ny < 0 || ny >= snapshot.h) continue;
          if (snapshot.alpha(nx, ny) > 100) nearArt = true;
        }
      }
      if (!nearArt) continue;
      const i = cell.idx(x, y);
      cell.px[i] = 255; cell.px[i + 1] = 255; cell.px[i + 2] = 255; cell.px[i + 3] = 255;
    }
  }
}

/// Source-over paste, skipping fully transparent source pixels.
function blit(src: Bitmap, dst: Bitmap, x0: number, y0: number): void {
  for (let y = 0; y < src.h; y++) {
    for (let x = 0; x < src.w; x++) {
      const dx = x0 + x, dy = y0 + y;
      if (dx < 0 || dx >= dst.w || dy < 0 || dy >= dst.h) continue;
      const s = src.idx(x, y);
      if (src.px[s + 3] === 0) continue;
      const d = dst.idx(dx, dy);
      dst.px[d] = src.px[s];
      dst.px[d + 1] = src.px[s + 1];
      dst.px[d + 2] = src.px[s + 2];
      dst.px[d + 3] = src.px[s + 3];
    }
  }
}

// MARK: - Load / save

function load(file: string): Bitmap {
  const image = nativeImage.createFromPath(file);
  if (image.isEmpty()) throw ImportErrors.unreadable();
  // The 1x representation, in pixels. A file named like "sheet@2x.png"
  // would otherwise report half its size.
  const raw = image.toBitmap({ scaleFactor: 1 });
  const { width } = image.getSize(1);
  if (width <= 0 || raw.length === 0 || raw.length % (width * 4) !== 0) throw ImportErrors.unreadable();
  const height = raw.length / (width * 4);
  return new Bitmap(width, height, new Uint8Array(raw.buffer, raw.byteOffset, raw.length).slice());
}

function png(bmp: Bitmap): Buffer {
  const img = nativeImage.createFromBitmap(Buffer.from(bmp.px.buffer, bmp.px.byteOffset, bmp.px.length),
    { width: bmp.w, height: bmp.h, scaleFactor: 1 });
  const data = img.toPNG();
  if (data.length === 0) throw ImportErrors.unreadable();
  return data;
}

/// Reads `file`, keys out the magenta, re-frames every cell, and returns
/// 256x640 PNG bytes ready to write to disk.
async function processFile(file: string): Promise<Buffer> {
  const src = load(file);
  const out = await processBitmap(src);
  return png(out);
}

export const SpriteSheetImporter = { process: processFile };
