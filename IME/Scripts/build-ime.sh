#!/usr/bin/env bash
# Builds the KEYI input method bundle without installing or registering it.
#
# Usage: Scripts/build-ime.sh [debug|release]
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIGURATION="${1:-debug}"
case "$CONFIGURATION" in
    debug|release) ;;
    *)
        echo "usage: Scripts/build-ime.sh [debug|release]" >&2
        exit 2
        ;;
esac

APP_NAME="KEYIIME"
BUILD_PATH="$PROJECT_ROOT/.build"
# Keep the build stage out of an `.app` path. LaunchServices may discover any
# `.app` that tools execute during verification, and a second bundle with the
# installed input source IDs makes TIS registration nondeterministic.
APP_BUNDLE="$BUILD_PATH/KEYIIME.staged"
LEGACY_APP_STAGE="$BUILD_PATH/KEYIIME.app"
RELEASE_ARCHIVE="$BUILD_PATH/KEYIIME-$CONFIGURATION.zip"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_FRAMEWORKS="$APP_CONTENTS/Frameworks"

echo "== Building KEYI input method ($CONFIGURATION) =="
cd "$PROJECT_ROOT"
swift build --configuration "$CONFIGURATION" --product KEYIIME

BIN_PATH="$(swift build --configuration "$CONFIGURATION" --product KEYIIME \
    --show-bin-path)"
APP_BINARY="$BIN_PATH/KEYIIME"
if [[ ! -x "$APP_BINARY" ]]; then
    echo "Build did not produce a KEYIIME executable at $APP_BINARY" >&2
    exit 1
fi

echo "== Staging bundle =="
# Rebuild the stage from scratch. An incremental stage can keep resources that
# a previous revision shipped, which would silently defeat the data whitelist
# enforced by verify-bundle.sh. Previous stages are moved aside with a
# non-`.app` suffix so LaunchServices cannot mistake them for install targets.
STALE_ROOT="$BUILD_PATH/stale-stages"
if [[ -d "$APP_BUNDLE" || -d "$LEGACY_APP_STAGE" ]]; then
    mkdir -p "$STALE_ROOT"
fi
if [[ -d "$APP_BUNDLE" ]]; then
    mv "$APP_BUNDLE" \
        "$STALE_ROOT/KEYIIME.staged.$(date +%Y%m%d-%H%M%S).$$"
fi
if [[ -d "$LEGACY_APP_STAGE" ]]; then
    mv "$LEGACY_APP_STAGE" \
        "$STALE_ROOT/KEYIIME.legacy-stage.$(date +%Y%m%d-%H%M%S).$$"
fi
mkdir -p "$APP_MACOS" "$APP_RESOURCES" "$APP_FRAMEWORKS"
cp "$APP_BINARY" "$APP_MACOS/KEYIIME"

# librime is a universal dylib that links as @rpath/librime.1.dylib, so the
# bundle ships it under that exact name plus the rpath dyld resolves.
cp "$PROJECT_ROOT/Vendor/librime/lib/librime.1.17.0.dylib" \
    "$APP_FRAMEWORKS/librime.1.dylib"

cp "$PROJECT_ROOT/resources/KeyiIME-Info.plist" "$APP_CONTENTS/Info.plist"
cp "$PROJECT_ROOT/Vendor/librime/LICENSE" \
    "$APP_RESOURCES/librime-LICENSE.txt"
cp "$PROJECT_ROOT/Vendor/ni/LICENSE" "$APP_RESOURCES/ni-input-method-LICENSE.txt"
cp "$PROJECT_ROOT/../LICENSE.md" "$APP_RESOURCES/KEYI-LICENSE.md"
cp "$PROJECT_ROOT/THIRD_PARTY_NOTICES.md" \
    "$APP_RESOURCES/THIRD_PARTY_NOTICES.md"
cp "$PROJECT_ROOT/SOURCES.md" "$APP_RESOURCES/SOURCES.md"
# Full licence texts for the static components linked into librime. They are
# packed so a distributed bundle carries its own notices instead of pointing at
# a URL that may move.
ditto "$PROJECT_ROOT/Vendor/librime/licenses" \
    "$APP_RESOURCES/licenses"
ditto "$PROJECT_ROOT/resources/rime" "$APP_RESOURCES/RimeData"
# 语音输入的本地识别：固定版本的 sherpa-onnx 运行库与 SenseVoice-Small 模型（fetch-sensevoice.sh
# 校验 sha256）。输入法运行时用 dlopen 加载运行库，不在编译时链接；模型约 230 MB。
SENSEVOICE_PATHS="$("$PROJECT_ROOT/Scripts/fetch-sensevoice.sh")"
SHERPA_LIB_DIR="$(sed -n 1p <<< "$SENSEVOICE_PATHS")"
SENSEVOICE_MODEL_DIR="$(sed -n 2p <<< "$SENSEVOICE_PATHS")"
cp "$SHERPA_LIB_DIR/libsherpa-onnx-c-api.dylib" "$SHERPA_LIB_DIR/libonnxruntime.dylib" "$APP_FRAMEWORKS/"
mkdir -p "$APP_RESOURCES/SenseVoice"
cp "$SENSEVOICE_MODEL_DIR/model.int8.onnx" "$SENSEVOICE_MODEL_DIR/tokens.txt" "$APP_RESOURCES/SenseVoice/"
cp "$PROJECT_ROOT/Vendor/sensevoice/MODEL_LICENSE" "$APP_RESOURCES/SenseVoice/MODEL_LICENSE"
cp "$PROJECT_ROOT/Vendor/sherpa-onnx/LICENSE" "$APP_RESOURCES/licenses/sherpa-onnx-Apache2.txt"
cp "$PROJECT_ROOT/Vendor/sherpa-onnx/onnxruntime-LICENSE" "$APP_RESOURCES/licenses/onnxruntime-MIT.txt"
# Localized bundle and input-mode names, so System Settings shows "KEYI 输入法 /
# KEYI 拼音" instead of the raw mode identifier.
ditto "$PROJECT_ROOT/resources/lproj" "$APP_RESOURCES"

"$PROJECT_ROOT/Scripts/generate-icon.sh" "$APP_RESOURCES"
# The app icon Finder shows is the same hummingbird as KEYI 可译 (one file, shared).
cp "$PROJECT_ROOT/../AppBundle/KEYI.icns" "$APP_RESOURCES/KEYI.icns"

chmod +x "$APP_MACOS/KEYIIME"

echo "== Signing (ad-hoc by default) =="
SIGNING_IDENTITY="${KEYI_IME_SIGNING_IDENTITY:--}"
codesign --force --sign "$SIGNING_IDENTITY" \
    --identifier "com.keyi.inputmethod.keyi" \
    "$APP_FRAMEWORKS/librime.1.dylib"
for SPEECH_LIBRARY in libonnxruntime.dylib libsherpa-onnx-c-api.dylib; do
    codesign --force --sign "$SIGNING_IDENTITY" "$APP_FRAMEWORKS/$SPEECH_LIBRARY"
done
codesign --force --sign "$SIGNING_IDENTITY" \
    --identifier "com.keyi.inputmethod.keyi" \
    "$APP_BUNDLE"
codesign --verify --strict "$APP_BUNDLE"

# Verified after signing: the check compares the code signature's Identifier
# with CFBundleIdentifier, so it must run once the bundle is actually signed.
echo "== Verifying bundle =="
plutil -lint "$APP_CONTENTS/Info.plist"
"$PROJECT_ROOT/Scripts/verify-bundle.sh" "$APP_BUNDLE"

echo "== Packaging installable archive =="
if [[ -f "$RELEASE_ARCHIVE" ]]; then
    mkdir -p "$STALE_ROOT"
    mv "$RELEASE_ARCHIVE" \
        "$STALE_ROOT/KEYIIME-$CONFIGURATION.zip.$(date +%Y%m%d-%H%M%S).$$"
fi
# Rename only the archive entry. No duplicate `.app` ever exists on disk in the
# build tree, while extraction still yields the conventional install name.
(
    cd "$BUILD_PATH"
    bsdtar -acf "$RELEASE_ARCHIVE" \
        -s '|^KEYIIME.staged|KEYIIME.app|' KEYIIME.staged
)
unzip -tq "$RELEASE_ARCHIVE" >/dev/null

echo
echo "Verified stage: $APP_BUNDLE"
echo "Installable archive: $RELEASE_ARCHIVE"
