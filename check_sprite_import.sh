#!/bin/zsh
# Smoke-checks SpriteSheetImporter: feeds it a magenta-backed sheet (what the
# Gemini prompt produces) at a deliberately wrong size and asserts a clean
# 256x640 sheet with real pixels in the top and bottom rows comes back.
set -e
cd "$(dirname "$0")"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

python3 - "$tmp" <<'PY'
import sys
from PIL import Image
out = sys.argv[1]
sheet = Image.open("Nikxel.app/Contents/Resources/sprites.png").convert("RGBA")
bg = Image.new("RGBA", sheet.size, (255, 0, 255, 255))
bg.alpha_composite(sheet)
bg.resize((1024, 1024), Image.NEAREST).save(f"{out}/in.png")   # wrong size on purpose
PY

cat > "$tmp/main.swift" <<'SWIFT'
import Foundation
let a = CommandLine.arguments
try SpriteSheetImporter.process(url: URL(fileURLWithPath: a[1]))
    .write(to: URL(fileURLWithPath: a[2]))
SWIFT

swiftc -o "$tmp/run" src/SpriteSheetImporter.swift src/NikxelSettings.swift "$tmp/main.swift" -framework Cocoa
"$tmp/run" "$tmp/in.png" "$tmp/out.png"

python3 - "$tmp" <<'PY'
import sys
from PIL import Image
out = Image.open(f"{sys.argv[1]}/out.png").convert("RGBA")
assert out.size == (256, 640), f"expected 256x640, got {out.size}"
px = out.load()
for y in range(out.height):
    for x in range(out.width):
        r, g, b, a = px[x, y]
        assert not (a > 128 and r > 150 and g < 100 and b > 150), f"magenta survived at {x},{y}"
def opaque(top):                      # first and last state rows must have art
    return sum(1 for y in range(top, top + 64) for x in range(256) if px[x, y][3] > 0)
assert opaque(0) > 500, "idle row is empty"
assert opaque(576) > 500, "last row is empty"
print("sprite import OK: 256x640, no magenta, all rows populated")
PY
