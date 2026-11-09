#!/usr/bin/env python3
"""Remove magenta bg, add white outline, slice to 256x640 (4 cols x 10 rows)."""
from PIL import Image
import os

SRC = "final_spritesheet.png" if os.path.exists("final_spritesheet.png") else "final_sprite.png"
img = Image.open(SRC).convert("RGBA")
print(f"Source: {SRC}")
w, h = img.size
print(f"Input: {w}x{h}")

# Aggressive chroma key: wider magenta detection + harden
removed, kept = 0, 0
for y in range(h):
    for x in range(w):
        r, g, b, a = img.getpixel((x, y))
        if a < 30:
            img.putpixel((x, y), (0, 0, 0, 0))
            continue
        # Wider magenta: R>150, G<100, B>150 catches edge magenta bleed
        if r > 150 and g < 100 and b > 150:
            img.putpixel((x, y), (0, 0, 0, 0))
            removed += 1
        else:
            img.putpixel((x, y), (r, g, b, 255))
            kept += 1
print(f"Removed: {removed}, Kept: {kept}")

# Aggressive edge clean: any pixel with magenta-like tint adjacent to character -> kill it
for _ in range(3):  # 3 passes to clean progressively
    for y in range(h):
        for x in range(w):
            r, g, b, a = img.getpixel((x, y))
            if a < 200:
                continue
            # If this pixel has any magenta tint (R and B both high, G low)
            if r > 100 and b > 100 and float(g) / max(r + b, 1) < 0.4:
                # Check if it's isolated near transparent area
                transparent_neighbors = 0
                for dy in (-1, 0, 1):
                    for dx in (-1, 0, 1):
                        nx, ny = x+dx, y+dy
                        if 0 <= nx < w and 0 <= ny < h:
                            if img.getpixel((nx, ny))[3] < 30:
                                transparent_neighbors += 1
                if transparent_neighbors >= 2:
                    img.putpixel((x, y), (0, 0, 0, 0))

# Harden: snap semi-transparent edges
for y in range(h):
    for x in range(w):
        r, g, b, a = img.getpixel((x, y))
        if 0 < a < 200:
            solid = False
            for dy in (-1, 0, 1):
                for dx in (-1, 0, 1):
                    nx, ny = x+dx, y+dy
                    if 0 <= nx < w and 0 <= ny < h:
                        if img.getpixel((nx, ny))[3] > 200:
                            solid = True
            if solid:
                img.putpixel((x, y), (r, g, b, 255))
            else:
                img.putpixel((x, y), (0, 0, 0, 0))

# Slice 10 rows x 4 cols → 256x640 output
ROWS, COLS = 10, 4
cw, rh = w // COLS, h // ROWS
result = Image.new("RGBA", (256, 640), (0, 0, 0, 0))

for row in range(ROWS):
    for col in range(COLS):
        x1, y1 = col * cw, row * rh
        x2, y2 = min(x1 + cw, w), min(y1 + rh, h)
        cell = img.crop((x1, y1, x2, y2))

        cx1, cy1, cx2, cy2 = cell.width, cell.height, 0, 0
        found = False
        for cy in range(cell.height):
            for cx in range(cell.width):
                if cell.getpixel((cx, cy))[3] > 30:
                    found = True
                    cx1, cy1 = min(cx1, cx), min(cy1, cy)
                    cx2, cy2 = max(cx2, cx), max(cy2, cy)

        if not found:
            continue

        cx1, cy1 = max(0, cx1 - 3), max(0, cy1 - 3)
        cx2, cy2 = min(cell.width - 1, cx2 + 3), min(cell.height - 1, cy2 + 3)

        try:
            char = cell.crop((cx1, cy1, cx2 + 1, cy2 + 1))
        except Exception:
            continue

        cw2, ch2 = char.size
        if cw2 < 1 or ch2 < 1:
            continue

        s = min(60.0 / cw2, 60.0 / ch2)
        nw, nh = max(1, int(cw2 * s)), max(1, int(ch2 * s))
        char = char.resize((nw, nh), Image.NEAREST)

        # Add 1px white outline around the character
        outline = Image.new("RGBA", (nw + 4, nh + 4), (0, 0, 0, 0))
        for oy in range(outline.height):
            for ox in range(outline.width):
                # Check if this is near a character pixel
                has_char_neighbor = False
                for dy in (-1, 0, 1):
                    for dx in (-1, 0, 1):
                        sx, sy = ox - 2 + dx, oy - 2 + dy
                        if 0 <= sx < nw and 0 <= sy < nh:
                            if char.getpixel((sx, sy))[3] > 100:
                                has_char_neighbor = True
                if has_char_neighbor:
                    # If this exact pixel isn't character, make it white outline
                    cx2, cy2 = ox - 2, oy - 2
                    is_char = False
                    if 0 <= cx2 < nw and 0 <= cy2 < nh:
                        if char.getpixel((cx2, cy2))[3] > 100:
                            is_char = True
                    if not is_char:
                        outline.putpixel((ox, oy), (255, 255, 255, 255))
        # Paste character on top of outline
        outline.paste(char, (2, 2), char)

        dx, dy = (64 - outline.width) // 2, (64 - outline.height) // 2
        result.paste(outline, (col * 64 + dx, row * 64 + dy), outline)

result.save("Nikxel.app/Contents/Resources/sprites.png")
print(f"Saved: Resources/sprites.png ({result.width}x{result.height})")
