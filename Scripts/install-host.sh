#!/bin/bash
# Builds Mice.app in Release and installs it to /Applications.
#
# The Accessibility grant follows the code signature, but macOS may still ask
# again for a binary it has not seen at this path — that is expected, and the
# app re-prompts on launch.
set -euo pipefail

cd "$(dirname "$0")/.."

DD="${DD:-build/dd}"
DEST="/Applications/Mice.app"

echo "==> Building Release"
xcodebuild -project Nimlet.xcodeproj -scheme NimletHost -configuration Release \
    -derivedDataPath "$DD" build | tail -2

BUILT="$DD/Build/Products/Release/Mice.app"
if [[ ! -d "$BUILT" ]]; then
    echo "error: expected $BUILT after a successful build" >&2
    exit 1
fi
# Read from the build rather than spelled out, so a fork signing with its own
# bundle prefix (Signing/Local.xcconfig) can replace its own earlier copy.
BUNDLE_ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$BUILT/Contents/Info.plist")

# Never replace something that isn't ours just because it shares a name.
if [[ -e "$DEST" ]]; then
    EXISTING=$(defaults read "$DEST/Contents/Info.plist" CFBundleIdentifier 2>/dev/null || echo "")
    if [[ "$EXISTING" != "$BUNDLE_ID" ]]; then
        echo "error: $DEST exists and is not Mice (bundle id: ${EXISTING:-unknown})." >&2
        echo "       Refusing to replace it. Move it aside and re-run." >&2
        exit 1
    fi
fi

# Only the copy being replaced. `pkill -x Mice` matches by process name, which
# on a machine with more than one checkout of this project also kills every
# dev build running out of a build directory — including somebody else's.
echo "==> Stopping the copy at $DEST"
pkill -f "$DEST/Contents/MacOS/Mice" 2>/dev/null || true
sleep 1

echo "==> Installing to $DEST"
rm -rf "$DEST"
cp -R "$BUILT" "$DEST"

echo "==> Verifying signature"
codesign --verify --deep --strict "$DEST" && echo "    signature ok"

echo "==> Launching and enabling launch at login"
open "$DEST" --args --enable-login-item

cat <<'NOTE'

Installed. Two things to check in the menu bar item:
  1. Accessibility — macOS may ask again for this copy. Without it, clicks
     and typing are silently ignored.
  2. Launch at login — enabled. Turn it off any time from the same menu.
     If macOS says it needs approval, it opens System Settings > Login Items.
NOTE
