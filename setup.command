#!/bin/bash
# One-shot setup: build Nikxel from source and launch it. Everything else --
# your own avatar, WhatsApp, which coding agent to use -- happens in the setup
# wizard that opens on first launch.
cd "$(dirname "$0")"
set -e

echo "Nikxel Setup"
echo "============"
echo ""

if ! xcode-select -p &> /dev/null; then
    echo "ERROR: Xcode Command Line Tools not found."
    echo "Run this first, then re-run setup.command:"
    echo "    xcode-select --install"
    exit 1
fi

echo "Building Nikxel.app (this takes a minute on first run)..."
./build.sh

echo ""
echo "Launching Nikxel..."
open Nikxel.app

echo ""
echo "Done. The setup wizard will walk you through the rest."
echo "Look for the pixel character on your screen, and Nikxel in the menu bar."
echo ""
echo "macOS will ask for permissions as you use each feature:"
echo "  Accessibility     - typing animation"
echo "  Microphone        - only while recording"
echo "  Screen Recording  - required to capture system audio"
echo "  Reminders         - only for the reminder bubbles"
