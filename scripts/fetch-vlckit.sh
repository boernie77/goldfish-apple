#!/bin/bash
# Lädt VLCKit (macOS-xcframework) von VideoLAN nach Frameworks/VLCKit.xcframework.
set -euo pipefail
VER="3.7.3-319ed2c0-79128878"
cd "$(dirname "$0")/.."
[ -d Frameworks/VLCKit.xcframework ] && { echo "VLCKit schon vorhanden"; exit 0; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
curl -fL -o "$T/v.tar.xz" "https://download.videolan.org/pub/cocoapods/prod/VLCKit-$VER.tar.xz"
tar -xf "$T/v.tar.xz" -C "$T"
mkdir -p Frameworks
ditto "$T/VLCKit - binary package/VLCKit.xcframework" Frameworks/VLCKit.xcframework
