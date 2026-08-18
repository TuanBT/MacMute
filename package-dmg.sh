#!/bin/bash
# Wraps dist/MacMute.app into a versioned .dmg with an Applications shortcut.
set -euo pipefail
cd "$(dirname "$0")"

APP="dist/MacMute.app"
[[ -d "$APP" ]] || { echo "Run ./build.sh first"; exit 1; }

VERSION=$(tr -d '[:space:]' < VERSION)
BUILD=$(tr -d '[:space:]' < BUILD)
DMG="dist/MacMute-${VERSION}-${BUILD}.dmg"
STAGE=$(mktemp -d)

cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

rm -f "$DMG"
hdiutil create -volname "MacMute $VERSION" -srcfolder "$STAGE" \
    -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"

echo "==> $DMG"
ls -lh "$DMG"
