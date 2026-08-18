#!/bin/bash
# Double-click this in Finder to build a MacMute release.
cd "$(dirname "$0")"

echo "======================================"
echo "  MacMute - Release Builder"
echo "======================================"
echo ""

bash ./build_release.sh "$@"

echo ""
echo "Press any key to close this window..."
read -n 1 -s
