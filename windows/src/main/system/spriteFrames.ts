import { nativeImage } from "electron";
import { resourcePath } from "../core/paths";
import { Sprites } from "../core/settings";

/// Every row of the active sprite sheet as PNG data URIs, for the pages that
/// draw the user's own character (the Nikxel window, the setup wizard). The
/// avatar on screen comes from this sheet; nikxel_avatar.png is only the
/// no-sheet fallback, one frame. Port of PageAssets.spriteRows.
export function spriteRows(): string[][] {
  const sheet = nativeImage.createFromPath(Sprites.activePath());
  const f = Sprites.frameSize;
  if (!sheet.isEmpty()) {
    const size = sheet.getSize(), rows: string[][] = [];
    for (let r = 0; r < Sprites.rows && (r + 1) * f <= size.height; r++) {
      const row: string[] = [];
      for (let c = 0; c < Sprites.cols && (c + 1) * f <= size.width; c++) {
        row.push(sheet.crop({ x: c * f, y: r * f, width: f, height: f }).toDataURL());
      }
      rows.push(row);
    }
    if (rows.length) return rows;
  }
  const fallback = nativeImage.createFromPath(resourcePath("nikxel_avatar.png"));
  return fallback.isEmpty() ? [] : [[fallback.toDataURL()]];
}
