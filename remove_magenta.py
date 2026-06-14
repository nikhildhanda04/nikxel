#!/usr/bin/env python3
"""Remove magenta background from sprite sheet. Usage: python3 remove_magenta.py [input_file]"""
import sys
from PIL import Image

INPUT = sys.argv[1] if len(sys.argv) > 1 else "final_sprite.png"
OUTPUT_DIR = "Nikxel.app/Contents/Resources/"

img = Image.open(INPUT).convert("RGBA")
w, h = img.size
print(f"Input: {INPUT} ({w}x{h})")

# Safety net: Gemini frequently ignores dimension constraints and produces sheets
# in odd sizes (e.g. 1024×1024, 13 rows instead of 10). The cell-slicing below
# divides by ROWS/COLS, so a wrongly-sized input produces sprites that look cut
# in half. Resize to the canonical 256×640 so slicing math always works — the
# characters may end up slightly stretched/squished, but all 40 poses render.
TARGET_W, TARGET_H = 256, 640
if (w, h) != (TARGET_W, TARGET_H):
    print(f"Resizing to {TARGET_W}×{TARGET_H} (input wasn't the expected size)")
    img = img.resize((TARGET_W, TARGET_H), Image.NEAREST)
    w, h = TARGET_W, TARGET_H

# Chroma key magenta -> transparent (R>150, G<100, B>150)
removed = 0
for y in range(h):
    for x in range(w):
        r, g, b, a = img.getpixel((x, y))
        if a < 30:
            img.putpixel((x, y), (0,0,0,0)); continue
        if r > 150 and g < 100 and b > 150:
            img.putpixel((x, y), (0,0,0,0)); removed += 1
        else:
            img.putpixel((x, y), (r, g, b, 255))
print(f"Magenta pixels removed: {removed}")

# Edge cleanup: 3 passes to remove magenta-tinted borders
for _ in range(3):
    for y in range(h):
        for x in range(w):
            r, g, b, a = img.getpixel((x, y))
            if a < 200: continue
            if r > 100 and b > 100 and float(g)/max(r+b,1) < 0.4:
                trans = 0
                for dy in (-1,0,1):
                    for dx in (-1,0,1):
                        nx, ny = x+dx, y+dy
                        if 0<=nx<w and 0<=ny<h and img.getpixel((nx,ny))[3]<30: trans+=1
                if trans >= 2: img.putpixel((x,y),(0,0,0,0))

# Harden edges
for y in range(h):
    for x in range(w):
        r, g, b, a = img.getpixel((x, y))
        if 0 < a < 200:
            solid = False
            for dy in (-1,0,1):
                for dx in (-1,0,1):
                    nx, ny = x+dx, y+dy
                    if 0<=nx<w and 0<=ny<h and img.getpixel((nx,ny))[3]>200: solid=True
            if solid: img.putpixel((x,y),(r,g,b,255))
            else: img.putpixel((x,y),(0,0,0,0))

# Slice 10 rows x 4 cols (idle, typing, thinking, done, dragging,
# pounce, petted, alert, recording, momReady)
ROWS, COLS = 10, 4
cw, rh = w // COLS, h // ROWS
result = Image.new("RGBA", (256, 640), (0,0,0,0))

for row in range(ROWS):
    for col in range(COLS):
        x1,y1 = col*cw, row*rh
        x2,y2 = min(x1+cw,w), min(y1+rh,h)
        cell = img.crop((x1,y1,x2,y2))
        cx1,cy1,cx2,cy2 = cell.width, cell.height, 0, 0
        found = False
        for cy in range(cell.height):
            for cx in range(cell.width):
                if cell.getpixel((cx,cy))[3] > 30:
                    found = True; cx1,cy1=min(cx1,cx),min(cy1,cy); cx2,cy2=max(cx2,cx),max(cy2,cy)
        if not found: continue
        cx1,cy1=max(0,cx1-3),max(0,cy1-3)
        cx2,cy2=min(cell.width-1,cx2+3),min(cell.height-1,cy2+3)
        try: char = cell.crop((cx1,cy1,cx2+1,cy2+1))
        except: continue
        cw2,ch2 = char.size
        if cw2<1 or ch2<1: continue
        s = min(60.0/cw2, 60.0/ch2)
        nw,nh = max(1,int(cw2*s)), max(1,int(ch2*s))
        char = char.resize((nw,nh), Image.NEAREST)

        # White outline
        out = Image.new("RGBA", (nw+4, nh+4), (0,0,0,0))
        for oy in range(out.height):
            for ox in range(out.width):
                near = False
                for dy in (-1,0,1):
                    for dx in (-1,0,1):
                        sx,sy = ox-2+dx, oy-2+dy
                        if 0<=sx<nw and 0<=sy<nh and char.getpixel((sx,sy))[3]>100: near=True
                if near:
                    cx3,cy3 = ox-2, oy-2
                    ischar = 0<=cx3<nw and 0<=cy3<nh and char.getpixel((cx3,cy3))[3]>100
                    if not ischar: out.putpixel((ox,oy),(255,255,255,255))
        out.paste(char, (2,2), char)
        dx,dy = (64-out.width)//2, (64-out.height)//2
        result.paste(out, (col*64+dx, row*64+dy), out)

result.save(OUTPUT_DIR + "sprites.png")
print(f"Saved: {OUTPUT_DIR}sprites.png ({result.width}x{result.height})")
print("Done! Double-click Nikxel.app to launch.")
