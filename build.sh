#!/bin/bash
# Builds MacMute.app into dist/. Pass --release to bump the build number first.
set -euo pipefail
cd "$(dirname "$0")"

VERSION=$(tr -d '[:space:]' < VERSION)
if [[ "${1:-}" == "--release" ]]; then
    BUILD=$(( $(tr -d '[:space:]' < BUILD) + 1 ))
    echo "$BUILD" > BUILD
else
    BUILD=$(tr -d '[:space:]' < BUILD)
fi

echo "==> Building MacMute $VERSION (build $BUILD)"
swift build -c release

APP="dist/MacMute.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/MacMute "$APP/Contents/MacOS/MacMute"
sed -e "s/__VERSION__/$VERSION/g" -e "s/__BUILD__/$BUILD/g" \
    Resources/Info.plist > "$APP/Contents/Info.plist"

# Feedback tones. Regenerate with ./ReleaseUtils/make-sounds.py if they change.
cp -R Resources/Sounds "$APP/Contents/Resources/Sounds"

# Optional app icon. Generate it with ./make-icon.sh; the build works without one.
if [[ -f Resources/AppIcon.icns ]]; then
    cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
else
    echo "    (no Resources/AppIcon.icns — run ./ReleaseUtils/make-icon.sh)"
fi

# Ad-hoc signature. Note: this changes on every build, so macOS asks you to
# re-approve Accessibility after each update.
codesign --force --sign - --identifier com.tuanbt.macmute "$APP"

echo "==> $APP ready"
