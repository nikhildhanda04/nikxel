#!/bin/bash
cd "$(dirname "$0")"
echo "Nikxel Setup"
echo "============"
echo ""

# Check for sprite sheet
if [ ! -f "final_sprite.png" ]; then
    echo "ERROR: final_sprite.png not found!"
    echo ""
    echo "Please:"
    echo "1. Open sprite_prompt.txt"
    echo "2. Copy the prompt → paste into Gemini with your photo"
    echo "3. Save the output as 'final_sprite.png' in this folder"
    echo "4. Run setup.command again"
    echo ""
    exit 1
fi

# Check Python
if ! command -v python3 &> /dev/null; then
    echo "ERROR: python3 not found. Install Python 3 first."
    exit 1
fi

# Check Pillow
python3 -c "from PIL import Image" 2>/dev/null
if [ $? -ne 0 ]; then
    echo "ERROR: Pillow not installed."
    echo "Run: pip3 install Pillow"
    exit 1
fi

# Process sprite
echo "Processing final_sprite.png..."
python3 remove_magenta.py final_sprite.png

if [ $? -ne 0 ]; then
    echo "ERROR: Sprite processing failed."
    exit 1
fi

echo ""
echo "Launching Nikxel..."
open Nikxel.app
echo ""
echo "Done! Look for the pixel character on your screen."
echo "Grant Accessibility permission if prompted (for typing detection)."
