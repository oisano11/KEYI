#!/bin/zsh

set -euo pipefail

SCRIPT_PATH="${(%):-%x}"
ROOT_DIR="${SCRIPT_PATH:A:h:h}"
BUILD_DIR="$ROOT_DIR/.build"
APP_DIR="$BUILD_DIR/KEYI 可译.app"

SIGNING_MODE="${KEYI_SIGNING_MODE:-development}"
if [[ "$SIGNING_MODE" != "development" && "$SIGNING_MODE" != "adhoc" && "$SIGNING_MODE" != "distribution" ]]; then
    echo "错误：KEYI_SIGNING_MODE 必须是 development、adhoc 或 distribution。" >&2
    exit 2
fi

SIGNING_IDENTITY=""
if [[ "$SIGNING_MODE" == "adhoc" ]]; then
    SIGNING_IDENTITY="-"
    TIMESTAMP_ARGS=(--timestamp=none)
elif [[ "$SIGNING_MODE" == "distribution" ]]; then
    if [[ -n "${KEYI_SIGNING_IDENTITY:-}" ]]; then
        SIGNING_IDENTITY="$KEYI_SIGNING_IDENTITY"
    else
        SIGNING_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
            | sed -nE 's/^[[:space:]]*[0-9]+\)[[:space:]]+[0-9A-F]+[[:space:]]+"(Developer ID Application: .*)"$/\1/p' \
            | head -n 1 || true)"
    fi
    if [[ -z "$SIGNING_IDENTITY" || "$SIGNING_IDENTITY" != "Developer ID Application: "* ]] \
        || ! security find-identity -v -p codesigning 2>/dev/null \
            | grep -Fq "\"$SIGNING_IDENTITY\""; then
        cat >&2 <<'EOF'
错误：正式分发模式需要 Apple Developer 的 Developer ID Application 证书。
请先在本机安装该有效证书，或设置 KEYI_SIGNING_IDENTITY 为其完整显示名称。
没有证书时请使用默认 development 模式；它只用于本地构建，不能作为受支持的正式分发包。
EOF
        exit 2
    fi
    TIMESTAMP_ARGS=(--timestamp)
else
    # 优先使用本机可用签名；没有时退回 ad-hoc。
    if [[ -n "${KEYI_SIGNING_IDENTITY:-}" ]]; then
        SIGNING_IDENTITY="$KEYI_SIGNING_IDENTITY"
    else
        SIGNING_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
            | sed -nE 's/^[[:space:]]*[0-9]+\)[[:space:]]+[0-9A-F]+[[:space:]]+"(.*)"$/\1/p' \
            | head -n 1 || true)"
        SIGNING_IDENTITY="${SIGNING_IDENTITY:--}"
    fi
    TIMESTAMP_ARGS=(--timestamp=none)
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
    "${TIMESTAMP_ARGS[@]}" \
    --sign "$SIGNING_IDENTITY" \
    "$APP_DIR"

echo "$APP_DIR"
