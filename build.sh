#!/bin/zsh
set -e
echo "Building Nikxel.app..."
mkdir -p Nikxel.app/Contents/MacOS Nikxel.app/Contents/Resources
# Ship the pre-made, tested sprite sheet so a fresh clone has a working avatar
# without running the custom-avatar scripts (generate_avatar.py, fix_sprites.py,
# remove_magenta.py). Those scripts overwrite this file in-place if you want to
# make your own avatar instead.
[ -f Nikxel.app/Contents/Resources/sprites.png ] || cp sprites.png Nikxel.app/Contents/Resources/sprites.png
# The onboarding "Your avatar" step copies this to the clipboard for Gemini.
cp sprite_prompt.txt Nikxel.app/Contents/Resources/sprite_prompt.txt
# Liquid Glass bubbles need the macOS 26 SDK. Build with `GLASS=1 ./build.sh` on a
# macOS 26 SDK; the default builds against older SDKs (bubbles just don't render).
if [ "${GLASS:-0}" = "1" ]; then
  TARGET=arm64-apple-macos26.0; GLASSFLAG="-D HAS_LIQUID_GLASS"
else
  TARGET=arm64-apple-macos15.0; GLASSFLAG=""
fi
swiftc -parse-as-library -target "$TARGET" $GLASSFLAG -o Nikxel.app/Contents/MacOS/Nikxel -framework Cocoa -framework CoreGraphics -framework ApplicationServices -framework QuartzCore -framework ScreenCaptureKit -framework AVFoundation -framework AudioToolbox -framework CoreMedia -framework Network -framework UserNotifications -framework EventKit src/*.swift
chmod +x Nikxel.app/Contents/MacOS/Nikxel
# macOS 15+ stamps com.apple.provenance on files it writes, and codesign
# refuses to sign a bundle carrying any extended attributes ("resource fork,
# Finder information, or similar detritus not allowed"). Strip them first.
xattr -cr Nikxel.app

# A stable self-signed cert is what keeps TCC permissions (Accessibility,
# Screen Recording) across rebuilds -- an ad-hoc signature changes whenever the
# binary does, so macOS treats each build as a new app and asks again.
#
# But that cert only exists on a machine where someone created it, and this
# script runs with `set -e`: on every other Mac `--sign "Nikxel"` failed with
# "Nikxel: no identity found" and took the whole build down with it, leaving an
# unsigned binary and no launched app. Fall back to ad-hoc and say what it
# costs, rather than refusing to finish.
if security find-identity -v -p codesigning 2>/dev/null | grep -q '"Nikxel"'; then
  SIGN_ID="Nikxel"
else
  SIGN_ID="-"
  echo ""
  echo "note: no 'Nikxel' code-signing certificate in your keychain, so this"
  echo "      build is signed ad-hoc. Everything works, but macOS will ask for"
  echo "      Accessibility and Screen Recording permission again after each"
  echo "      rebuild. Creating the certificate once stops that -- see"
  echo "      'Keeping permissions across rebuilds' in the README."
  echo ""
fi
codesign --force --deep --sign "$SIGN_ID" Nikxel.app
echo "Build complete: Nikxel.app"
