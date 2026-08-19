#!/bin/bash
# One-shot release build for MacMute.
#
#   ./ReleaseUtils/build_release.sh            build with the current build number
#   ./ReleaseUtils/build_release.sh --bump     bump BUILD first
#
# Produces, in dist/:
#   MacMute.app                    the app bundle
#   MacMute-<ver>-<build>.dmg      drag-to-Applications image (upload this)
#   MacMute-<ver>-<build>.zip      same app, zipped
#   MacMute-<ver>-<build>.pkg      installer that quits the old copy and opens the new one
set -euo pipefail
cd "$(dirname "$0")/.."

echo "🚀 MacMute release build"

if ! xcode-select -p &> /dev/null; then
    echo "❌ Xcode command line tools not found — run: xcode-select --install"
    exit 1
fi

# Icon: rebuilt only when the render is newer than the generated .icns.
if [[ -f Resources/AppIcon.source.jpg || -f Resources/AppIcon.source.png ]]; then
    if [[ ! -f Resources/AppIcon.icns ]] \
       || [[ Resources/AppIcon.source.jpg -nt Resources/AppIcon.icns ]] \
       || [[ Resources/AppIcon.source.png -nt Resources/AppIcon.icns ]]; then
        echo "🎨 Rebuilding app icon"
        ./ReleaseUtils/make-icon.sh
    fi
fi

echo "🧹 Cleaning dist/"
rm -rf dist

if [[ "${1:-}" == "--bump" ]]; then
    ./build.sh --release
else
    ./build.sh
fi

VERSION=$(tr -d '[:space:]' < VERSION)
BUILD=$(tr -d '[:space:]' < BUILD)
STEM="dist/MacMute-${VERSION}-${BUILD}"

echo "📦 Creating .dmg"
./package-dmg.sh >/dev/null

echo "📦 Creating .zip"
ditto -c -k --keepParent dist/MacMute.app "${STEM}.zip"

echo "📦 Creating .pkg"
# pkg-scripts holds only preinstall/postinstall: pkgbuild ships every file in the
# directory it is given, and the rest of ReleaseUtils is build tooling.
pkgbuild --root dist/MacMute.app \
         --scripts ReleaseUtils/pkg-scripts \
         --identifier com.tuanbt.macmute \
         --version "$VERSION" \
         --install-location /Applications/MacMute.app \
         "${STEM}.pkg" >/dev/null

echo ""
echo "🎉 Done — dist/:"
ls -lh dist | tail -n +2 | awk '{printf "   %-34s %s\n", $9, $5}'
echo ""
echo "📝 Next steps:"
echo "   git tag v$VERSION && git push origin v$VERSION"
echo "   ...or upload ${STEM}.dmg manually at:"
echo "   https://github.com/TuanBT/MacMute/releases/new"
