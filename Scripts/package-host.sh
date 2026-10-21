#!/bin/bash
# Build a versioned, signed Nimlet companion without replacing installed apps.
set -euo pipefail
cd "$(dirname "$0")/.."
MODE="${1:-build}"
if [[ "$MODE" != build && "$MODE" != notarize ]]; then
    echo 'Usage: Scripts/package-host.sh [build|notarize]' >&2
    exit 2
fi
DD="${NIMLET_DERIVED_DATA:-build/nimlet-release}"
IDENTITY="${NIMLET_SIGN_IDENTITY:-Developer ID Application: Renyi Cao (HG29U745Q5)}"
xcodegen generate
RELEASE_CONFIG=()
if [[ -n "${NIMLET_RELEASE_XCCONFIG:-}" ]]; then
    RELEASE_CONFIG=(-xcconfig "$NIMLET_RELEASE_XCCONFIG")
fi
xcodebuild -project Nimlet.xcodeproj -scheme NimletHost -configuration Release \
    -destination 'generic/platform=macOS' -derivedDataPath "$DD" \
    "${RELEASE_CONFIG[@]}" ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO build
BUILT="$DD/Build/Products/Release/Mice.app"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$BUILT/Contents/Info.plist")
BUILD=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$BUILT/Contents/Info.plist")
OUT="dist/Nimlet-${VERSION}-${BUILD}-$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$OUT"
ditto "$BUILT" "$OUT/Nimlet.app"
mkdir -p "$OUT/Nimlet.app/Contents/Resources"
cp LICENSE "$OUT/Nimlet.app/Contents/Resources/LICENSE.txt"
cp THIRD-PARTY-NOTICES.txt "$OUT/Nimlet.app/Contents/Resources/THIRD-PARTY-NOTICES.txt"
# The bundled command-line tool is nested code: it has to carry its own
# hardened-runtime signature before the app's seal is written over it, or
# notarization rejects the whole bundle for the helper's sake.
CLI="$OUT/Nimlet.app/Contents/Helpers/nimlet"
[[ -x "$CLI" ]] || { echo "The nimlet CLI is missing from the bundle at $CLI" >&2; exit 1; }
codesign --force --options runtime --timestamp --sign "$IDENTITY" "$CLI"
codesign --force --options runtime --timestamp \
    --entitlements Signing/NimletHost.entitlements --sign "$IDENTITY" "$OUT/Nimlet.app"
codesign --verify --strict --verbose=2 "$OUT/Nimlet.app"
for BINARY in "$OUT/Nimlet.app/Contents/MacOS/Mice" "$CLI"; do
    ARCHITECTURES=$(lipo -archs "$BINARY")
    [[ " $ARCHITECTURES " == *' arm64 '* && " $ARCHITECTURES " == *' x86_64 '* ]] || {
        echo "Expected a universal binary at $BINARY; found: $ARCHITECTURES" >&2; exit 1;
    }
done
ditto -c -k --keepParent "$OUT/Nimlet.app" "$OUT/Nimlet.zip"
if [[ "$MODE" == notarize ]]; then
    : "${NIMLET_NOTARY_PROFILE:?Set NIMLET_NOTARY_PROFILE to an existing notarytool Keychain profile}"
    xcrun notarytool submit "$OUT/Nimlet.zip" --keychain-profile "$NIMLET_NOTARY_PROFILE" \
        --wait --output-format json > "$OUT/notary-result.json"
    /usr/bin/plutil -extract status raw "$OUT/notary-result.json" | /usr/bin/grep -qx Accepted
    xcrun stapler staple "$OUT/Nimlet.app"
    xcrun stapler validate "$OUT/Nimlet.app"
    spctl --assess --type execute --verbose=2 "$OUT/Nimlet.app"
    ditto -c -k --keepParent "$OUT/Nimlet.app" "$OUT/Nimlet.zip"
    echo 'Notarized, stapled and assessed.' > "$OUT/distribution-status.txt"
else
    echo 'Signed only. NOT notarized; do not publish this package.' > "$OUT/distribution-status.txt"
fi
shasum -a 256 "$OUT/Nimlet.zip" > "$OUT/SHA256SUMS"
# What the installed app's update check reads. Publish this file as
# https://nimlet.app/releases/latest.json and the zip at the URL it names, and
# every running copy older than $BUILD offers the download from its menu.
SITE_ORIGIN="${NIMLET_SITE_ORIGIN:-https://nimlet.app}"
cat > "$OUT/latest.json" <<EOF
{
  "version": "$VERSION",
  "build": $BUILD,
  "url": "$SITE_ORIGIN/releases/Nimlet-$VERSION-$BUILD.zip",
  "date": "$(date -u +%Y-%m-%d)",
  "sha256": "$(cut -d' ' -f1 "$OUT/SHA256SUMS")",
  "notes": "${NIMLET_RELEASE_NOTES:-}"
}
EOF
cp "$OUT/Nimlet.zip" "$OUT/Nimlet-$VERSION-$BUILD.zip"
mkdir -p build/release-prep
printf '%s\n' "$OUT" > build/release-prep/latest-host-package.txt
cat "$OUT/distribution-status.txt"
echo "Package: $OUT/Nimlet.zip"
echo "Upload $OUT/Nimlet-$VERSION-$BUILD.zip to $SITE_ORIGIN/releases/ and $OUT/latest.json to $SITE_ORIGIN/releases/latest.json"
