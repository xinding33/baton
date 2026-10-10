#!/bin/bash
# Builds dist/Baton.app and dist/Baton.zip: universal (Apple silicon and Intel) unless
# BATON_ARCHS=native. Ad-hoc signed by default; set SIGN_IDENTITY to sign with a certificate
# instead, which also turns the hardened runtime on.
#
# The result is a development build, which never replaces itself with a release, unless
# BATON_BUILD=release. scripts/release.sh makes the releases; scripts/deploy.sh installs
# development builds on the owner's Macs.
set -euo pipefail
cd "$(dirname "$0")/.."
# Releases pass BATON_VERSION from the tag; other builds use the latest tag.
VERSION="${BATON_VERSION:-$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || true)}"
VERSION="${VERSION:-0.0.0}"
IDENTITY="${SIGN_IDENTITY:--}"
ARCHS=(--arch arm64 --arch x86_64)
if [ "${BATON_ARCHS:-universal}" = native ]; then ARCHS=(); fi
swift build -c release ${ARCHS[@]+"${ARCHS[@]}"} 2>&1 | tail -1
BIN_DIR="$(swift build -c release ${ARCHS[@]+"${ARCHS[@]}"} --show-bin-path)"

rm -rf dist
APP="$PWD/dist/Baton.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Baton" "$APP/Contents/MacOS/Baton"
cp scripts/Info.plist "$APP/Contents/Info.plist"
plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$VERSION" "$APP/Contents/Info.plist"
plutil -replace BatonBuild -string "${BATON_BUILD:-development}" "$APP/Contents/Info.plist"
cp LICENSE "$APP/Contents/Resources/LICENSE"

if [ "$IDENTITY" = "-" ]; then
  codesign --force --sign - "$APP"
elif [ "${BATON_BUILD:-development}" = release ]; then
  codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
else
  # Only notarization needs Apple's timestamp, and a deploy should not need the internet.
  codesign --force --options runtime --timestamp=none --sign "$IDENTITY" "$APP"
fi
codesign --verify --strict "$APP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$PWD/dist/Baton.zip"
printf 'Built: %s (%s, %s build)\n' "$APP" "$VERSION" "${BATON_BUILD:-development}"
