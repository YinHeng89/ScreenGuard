#!/bin/zsh
set -euo pipefail

RES="${0:A:h}"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

SOURCE="$TMP/icon_1024.png"
swift "$RES/generate_icon.swift" "$SOURCE" >/dev/null

mkdir -p "$TMP/ScreenGuard.iconset"
ICONSET="$TMP/ScreenGuard.iconset"

sips -z 16 16    "$SOURCE" --out "$ICONSET/icon_16x16.png"      >/dev/null
sips -z 32 32    "$SOURCE" --out "$ICONSET/icon_16x16@2x.png"   >/dev/null
sips -z 32 32    "$SOURCE" --out "$ICONSET/icon_32x32.png"      >/dev/null
sips -z 64 64    "$SOURCE" --out "$ICONSET/icon_32x32@2x.png"   >/dev/null
sips -z 128 128  "$SOURCE" --out "$ICONSET/icon_128x128.png"    >/dev/null
sips -z 256 256  "$SOURCE" --out "$ICONSET/icon_128x128@2x.png" >/dev/null
sips -z 256 256  "$SOURCE" --out "$ICONSET/icon_256x256.png"    >/dev/null
sips -z 512 512  "$SOURCE" --out "$ICONSET/icon_256x256@2x.png" >/dev/null
sips -z 512 512  "$SOURCE" --out "$ICONSET/icon_512x512.png"    >/dev/null
cp "$SOURCE" "$ICONSET/icon_512x512@2x.png"

iconutil -c icns -o "$RES/AppIcon.icns" "$ICONSET"
echo "$RES/AppIcon.icns"
