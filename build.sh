#!/bin/zsh
set -e
echo "Building Nikxel.app..."
mkdir -p Nikxel.app/Contents/MacOS Nikxel.app/Contents/Resources
swiftc -parse-as-library -o Nikxel.app/Contents/MacOS/Nikxel -framework Cocoa -framework CoreGraphics -framework ApplicationServices src/*.swift
chmod +x Nikxel.app/Contents/MacOS/Nikxel
codesign --force --deep --sign - Nikxel.app
echo "Build complete: Nikxel.app"
