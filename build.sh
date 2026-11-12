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
# The clone this was built from, so Check for Updates finds it even when the
# app is opened from a copy or link elsewhere (Applications, Dock, login item).
echo "$PWD" > Nikxel.app/Contents/Resources/repo_path
# The commit this binary is, which can trail the clone's HEAD when a pull
# succeeded but the build after it didn't.
git rev-parse HEAD > Nikxel.app/Contents/Resources/commit 2>/dev/null || true
# Optional shared Google OAuth client. With it, "Connect Google" is one click
# (no Cloud Console); without it, users bring their own via the paste flow.
if [ -f google_client.json ]; then cp google_client.json Nikxel.app/Contents/Resources/google_client.json; fi
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
# binary does, so macOS treats each build (and every Check for Updates) as a
# new app: the old toggle stays on for a build that no longer exists, and
# recording fails with "user declined TCCs".
#
# So when there's no "Nikxel" cert, make one: in its own keychain with a
# known password, so nothing prompts. Untrusted is fine -- codesign signs
# with it and TCC only matches the leaf. Any failure falls back to ad-hoc
# rather than failing the build (`set -e`).
KC="$HOME/.nikxel/signing.keychain-db"
has_cert() { security find-identity -p codesigning 2>/dev/null | grep -q '"Nikxel"'; }
if ! has_cert; then
  (
    set -e
    if [ ! -f "$KC" ]; then
      echo "Creating a 'Nikxel' signing certificate (once) so permissions survive updates..."
      T="$(mktemp -d)"
      openssl req -x509 -newkey rsa:2048 -nodes -keyout "$T/k.pem" -out "$T/c.pem" -days 7300 \
        -subj "/CN=Nikxel" -addext "extendedKeyUsage=critical,codeSigning" \
        -addext "keyUsage=critical,digitalSignature" -addext "basicConstraints=critical,CA:false" 2>/dev/null
      openssl pkcs12 -export -inkey "$T/k.pem" -in "$T/c.pem" -out "$T/k.p12" -passout pass:nikxel
      mkdir -p "$HOME/.nikxel"
      security create-keychain -p nikxel "$KC"
      security set-keychain-settings "$KC"
      security import "$T/k.p12" -k "$KC" -P nikxel -T /usr/bin/codesign >/dev/null
      security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k nikxel "$KC" >/dev/null
      rm -rf "$T"
    fi
    security unlock-keychain -p nikxel "$KC"
    # codesign only looks in the search list.
    security list-keychains -d user | grep -q "signing.keychain" ||
      security list-keychains -d user -s "$KC" $(security list-keychains -d user | xargs)
  ) || echo "note: couldn't create the signing certificate; signing ad-hoc."
else
  [ -f "$KC" ] && security unlock-keychain -p nikxel "$KC" 2>/dev/null || true
fi
if has_cert; then
  SIGN_ID="Nikxel"
else
  SIGN_ID="-"
  echo ""
  echo "note: signed ad-hoc, so macOS will ask for Accessibility and Screen"
  echo "      Recording permission again after each rebuild. See 'Keeping"
  echo "      permissions across rebuilds' in the README."
  echo ""
fi
codesign --force --deep --sign "$SIGN_ID" Nikxel.app
# Launch Services caches the icon from the first time it saw this bundle;
# re-register so Finder/Launchpad pick up AppIcon.icns.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f Nikxel.app 2>/dev/null || true

# Show up in Applications (Finder, Launchpad, Spotlight) as a link to this
# build, not a copy: a copy has no git folder, so Check for Updates couldn't
# update it, and launching through a link runs this exact bundle. Refreshed
# every build in case the clone moved. A dragged-in copy of Nikxel is stale
# and can't update, so it's swapped for the link; any other app is left alone.
# ~/Applications when /Applications isn't writable (non-admin user).
APPS=/Applications; [ -w "$APPS" ] || { APPS="$HOME/Applications"; mkdir -p "$APPS"; }
if [ "$PWD" != "$APPS" ] && [ -d "$APPS/Nikxel.app" ] && [ ! -L "$APPS/Nikxel.app" ] && [ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$APPS/Nikxel.app/Contents/Info.plist" 2>/dev/null)" = com.nikxel.Nikxel ]; then
  rm -rf "$APPS/Nikxel.app" && echo "Replaced the old copy in $APPS"
fi
if [ -L "$APPS/Nikxel.app" ] || [ ! -e "$APPS/Nikxel.app" ]; then
  ln -sfn "$PWD/Nikxel.app" "$APPS/Nikxel.app" && echo "Linked into $APPS"
fi
echo "Build complete: Nikxel.app"
