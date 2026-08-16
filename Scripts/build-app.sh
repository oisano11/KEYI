#!/bin/zsh

set -euo pipefail

SCRIPT_PATH="${(%):-%x}"
ROOT_DIR="${SCRIPT_PATH:A:h:h}"
BUILD_DIR="$ROOT_DIR/.build"
APP_DIR="$BUILD_DIR/KEYI 可译.app"
SIGNING_IDENTITY="${KEYI_SIGNING_IDENTITY:--}"

cd "$ROOT_DIR"
swift build -c release --product KEYI

BIN_DIR="$(swift build -c release --show-bin-path)"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BIN_DIR/KEYI" "$APP_DIR/Contents/MacOS/KEYI"
cp "$ROOT_DIR/AppBundle/Info.plist" "$APP_DIR/Contents/Info.plist"
cp "$ROOT_DIR/AppBundle/PkgInfo" "$APP_DIR/Contents/PkgInfo"
cp "$ROOT_DIR/AppBundle/KEYI.icns" "$APP_DIR/Contents/Resources/KEYI.icns"
chmod +x "$APP_DIR/Contents/MacOS/KEYI"
codesign \
    --force \
    --options runtime \
    --timestamp=none \
    --sign "$SIGNING_IDENTITY" \
    "$APP_DIR"

echo "$APP_DIR"
