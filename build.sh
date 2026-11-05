#!/bin/zsh
set -e
echo "Building Nikxel.app (universal: arm64 + x86_64, macOS 13+)..."
mkdir -p Nikxel.app/Contents/MacOS Nikxel.app/Contents/Resources
mkdir -p build/arm64 build/x86_64

# Ship the pre-made, tested sprite sheet so a fresh clone has a working avatar
# without going through setup.command's custom-avatar flow. setup.command
# overwrites this file in-place if you want to make your own avatar instead.
[ -f Nikxel.app/Contents/Resources/sprites.png ] || cp sprites.png Nikxel.app/Contents/Resources/sprites.png

FRAMEWORKS=(-framework Cocoa -framework CoreGraphics -framework ApplicationServices -framework QuartzCore -framework ScreenCaptureKit -framework AVFoundation -framework AudioToolbox -framework CoreMedia -framework Network -framework UserNotifications -framework EventKit)

swiftc -parse-as-library -target arm64-apple-macos13.0 -o build/arm64/Nikxel "${FRAMEWORKS[@]}" src/*.swift
swiftc -parse-as-library -target x86_64-apple-macos13.0 -o build/x86_64/Nikxel "${FRAMEWORKS[@]}" src/*.swift

lipo -create -output Nikxel.app/Contents/MacOS/Nikxel build/arm64/Nikxel build/x86_64/Nikxel
chmod +x Nikxel.app/Contents/MacOS/Nikxel
rm -rf build

codesign --force --deep --sign - Nikxel.app
echo "Build complete: Nikxel.app"
file Nikxel.app/Contents/MacOS/Nikxel
