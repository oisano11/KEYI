#!/bin/zsh

set -euo pipefail

SCRIPT_PATH="${(%):-%x}"
ROOT_DIR="${SCRIPT_PATH:A:h:h}"
BUILD_DIR="$ROOT_DIR/.build"
APP_DIR="$BUILD_DIR/KEYI 可译.app"

# 优先使用本地自签名开发证书：签名身份稳定，辅助功能等隐私授权不会
# 因为每次重编译的 ad-hoc 签名变化而失效。找不到证书时退回 ad-hoc。
if [[ -n "${KEYI_SIGNING_IDENTITY:-}" ]]; then
    SIGNING_IDENTITY="$KEYI_SIGNING_IDENTITY"
elif security find-identity -p codesigning 2>/dev/null \
    | grep -q '"KEYI Development Signing"'; then
    SIGNING_IDENTITY="KEYI Development Signing"
else
    SIGNING_IDENTITY="-"
fi

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
