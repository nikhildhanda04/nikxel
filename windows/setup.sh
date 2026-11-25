#!/usr/bin/env bash
# Builds Nikxel from this clone on Linux and starts it. Run it again any time
# to rebuild. Linux support is early: see "Install (Linux)" in the README.
set -e
cd "$(dirname "$0")"
DIR="$PWD"

if ! command -v node >/dev/null; then
  echo "Nikxel needs Node.js 20 or later: https://nodejs.org (or: sudo apt install nodejs npm)"
  exit 1
fi
if ! command -v git >/dev/null; then
  echo "Nikxel needs Git (Check for Updates pulls with it): sudo apt install git"
  exit 1
fi

# A running copy keeps the old code loaded; quit it first.
pkill -f "electron/dist/electron $DIR" 2>/dev/null || true

echo "Installing dependencies..."
npm ci --no-audit --no-fund
# npm 11.16+ skips install scripts allowScripts doesn't approve, and the
# electron and ffmpeg binaries come from those scripts.
[ -x node_modules/electron/dist/electron ] || node node_modules/electron/install.js
[ -x node_modules/ffmpeg-static/ffmpeg ] || node node_modules/ffmpeg-static/install.js
echo "Building Nikxel..."
npm run build

# Electron's login-item setting does nothing on Linux: add a menu entry and
# start at login with .desktop files. --ozone-platform=x11 runs it under
# XWayland, where the avatar can stay on top and place itself.
RUN="\"$DIR/node_modules/electron/dist/electron\" \"$DIR\" --ozone-platform=x11"
ENTRY="[Desktop Entry]
Type=Application
Name=Nikxel
Comment=A tiny pixel desktop companion
Exec=$RUN
Icon=$DIR/resources/icon.png
Categories=Utility;
Terminal=false"
mkdir -p ~/.local/share/applications ~/.config/autostart
printf '%s\n' "$ENTRY" > ~/.local/share/applications/nikxel.desktop
printf '%s\n' "$ENTRY" > ~/.config/autostart/nikxel.desktop

echo "Starting Nikxel. You can close this terminal; Nikxel keeps running."
nohup "$DIR/node_modules/electron/dist/electron" "$DIR" --ozone-platform=x11 >/dev/null 2>&1 &
