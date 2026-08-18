#!/bin/bash
# Builds the app icon from a single source render.
#
#   Resources/AppIcon.source.(jpg|png)   the raw 1024px source render
#     -> Resources/AppIcon.png           masked 1024px master (rounded tile, clear corners)
#     -> Resources/AppIcon.icns          what the app bundle ships
#     -> assets/icon.png                 what the README shows
set -euo pipefail
cd "$(dirname "$0")/.."

SRC=""
for candidate in Resources/AppIcon.source.png Resources/AppIcon.source.jpg; do
    [[ -f "$candidate" ]] && SRC="$candidate" && break
done
[[ -n "$SRC" ]] || { echo "No Resources/AppIcon.source.png|jpg — see the App icon section in README.md"; exit 1; }

echo "==> Masking $SRC"
swift ReleaseUtils/mask-icon.swift "$SRC" Resources/AppIcon.png

TMP=$(mktemp -d)
SET="$TMP/AppIcon.iconset"
mkdir -p "$SET"

# name -> pixel size, as expected by iconutil
render() { sips -z "$2" "$2" Resources/AppIcon.png --out "$SET/$1" >/dev/null; }
render icon_16x16.png        16
render icon_16x16@2x.png     32
render icon_32x32.png        32
render icon_32x32@2x.png     64
render icon_128x128.png     128
render icon_128x128@2x.png  256
render icon_256x256.png     256
render icon_256x256@2x.png  512
render icon_512x512.png     512
render icon_512x512@2x.png 1024

iconutil -c icns "$SET" -o Resources/AppIcon.icns
rm -rf "$TMP"

mkdir -p assets
cp Resources/AppIcon.png assets/icon.png

echo "==> Resources/AppIcon.icns and assets/icon.png"
