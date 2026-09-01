#!/bin/zsh

set -euo pipefail

SCRIPT_PATH="${(%):-%x}"
ROOT_DIR="${SCRIPT_PATH:A:h:h}"
OUTPUT_DIR="$ROOT_DIR/.build/binary-release"
MAC_APP="$ROOT_DIR/.build/KEYI 可译.app"
WINDOWS_DIR="$ROOT_DIR/.build/windows"

if [[ -n "$(git -C "$ROOT_DIR" status --porcelain --untracked-files=no)" ]]; then
    echo "错误：工作树存在未提交的跟踪文件；请先提交后再打包。" >&2
    exit 2
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT_DIR/AppBundle/Info.plist")"
WINDOWS_VERSION="$(sed -nE 's/^[[:space:]]*<Version>([^<]+)<\/Version>$/\1/p' "$ROOT_DIR/Windows/KEYI.Windows/KEYI.Windows.csproj")"
if [[ -z "$VERSION" || "$VERSION" != "$WINDOWS_VERSION" ]]; then
    echo "错误：macOS/Windows 版本不一致。" >&2
    exit 1
fi

SOURCE_COMMIT="$(git -C "$ROOT_DIR" rev-parse HEAD)"
rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"

echo "运行源码与 macOS 检查..."
"$ROOT_DIR/Scripts/test.sh"

echo "构建 macOS 实验包..."
KEYI_SIGNING_MODE=development "$ROOT_DIR/Scripts/build-app.sh"
codesign --verify --deep --strict --verbose=2 "$MAC_APP"

MAC_IDENTITY="$(codesign -dv --verbose=4 "$MAC_APP" 2>&1 | sed -n 's/^Authority=//p' | head -n 1 || true)"
MAC_TEAM_ID="$(codesign -dv --verbose=4 "$MAC_APP" 2>&1 | sed -n 's/^TeamIdentifier=//p' | head -n 1 || true)"
if spctl --assess --type execute "$MAC_APP" >/dev/null 2>&1; then
    MAC_GATEKEEPER="accepted"
else
    MAC_GATEKEEPER="rejected"
fi
if [[ "$MAC_IDENTITY" == "-" || -z "$MAC_IDENTITY" ]]; then
    MAC_SIGNATURE="ad-hoc"
else
    MAC_SIGNATURE="self-signed"
fi

MAC_ARCH="$(uname -m)"
MAC_ZIP="$OUTPUT_DIR/KEYI-v${VERSION}-macOS-${MAC_ARCH}-experimental.zip"
ditto -c -k --sequesterRsrc --keepParent "$MAC_APP" "$MAC_ZIP"

DMG_STAGING="$(mktemp -d)"
trap 'rm -rf "$DMG_STAGING"' EXIT
ditto "$MAC_APP" "$DMG_STAGING/KEYI 可译.app"
ln -s /Applications "$DMG_STAGING/Applications"
MAC_DMG="$OUTPUT_DIR/KEYI-v${VERSION}-macOS-${MAC_ARCH}-experimental.dmg"
hdiutil create \
    -volname "KEYI 可译" \
    -srcfolder "$DMG_STAGING" \
    -ov \
    -format UDZO \
    "$MAC_DMG" >/dev/null

echo "构建 Windows 实验包..."
"$ROOT_DIR/Scripts/build-windows.sh"
WINDOWS_SETUP="$WINDOWS_DIR/KEYI-Setup.exe"
WINDOWS_PORTABLE="$WINDOWS_DIR/app/KEYI.exe"
if [[ ! -f "$WINDOWS_SETUP" || ! -f "$WINDOWS_PORTABLE" ]]; then
    echo "错误：Windows 构建产物缺失。" >&2
    exit 1
fi

WINDOWS_SETUP_ARTIFACT="$OUTPUT_DIR/KEYI-v${VERSION}-Windows-x64-experimental-setup.exe"
WINDOWS_PORTABLE_ARTIFACT="$OUTPUT_DIR/KEYI-v${VERSION}-Windows-x64-experimental-portable.exe"
cp "$WINDOWS_SETUP" "$WINDOWS_SETUP_ARTIFACT"
cp "$WINDOWS_PORTABLE" "$WINDOWS_PORTABLE_ARTIFACT"

MAC_SHA256="$(shasum -a 256 "$MAC_ZIP" | awk '{print $1}')"
MAC_DMG_SHA256="$(shasum -a 256 "$MAC_DMG" | awk '{print $1}')"
WINDOWS_SETUP_SHA256="$(shasum -a 256 "$WINDOWS_SETUP_ARTIFACT" | awk '{print $1}')"
WINDOWS_PORTABLE_SHA256="$(shasum -a 256 "$WINDOWS_PORTABLE_ARTIFACT" | awk '{print $1}')"
CHECKSUMS="$OUTPUT_DIR/SHA256SUMS.txt"
{
    shasum -a 256 "$MAC_DMG" "$MAC_ZIP" "$WINDOWS_SETUP_ARTIFACT" "$WINDOWS_PORTABLE_ARTIFACT" \
        | sed "s#${OUTPUT_DIR}/##"
} > "$CHECKSUMS"

README_FILE="$OUTPUT_DIR/BINARY-README.txt"
printf '%s\n' \
    "KEYI 可译 v${VERSION} 二进制实验版" \
    "" \
    "这是未公证/未受平台发行者信任的实验构建，不是受支持的正式安装包。" \
    "" \
    "macOS：DMG 与 ZIP 内的应用使用本机开发签名（${MAC_SIGNATURE}，身份：${MAC_IDENTITY:-none}，Team ID：${MAC_TEAM_ID:-not-set}），Gatekeeper 状态：${MAC_GATEKEEPER}。" \
    "打开 DMG 后，将 KEYI 可译拖到 Applications。" \
    "首次打开请在 Finder 中右键选择“打开”，不要关闭系统级 Gatekeeper。" \
    "" \
    "Windows：安装器和便携程序未使用 Authenticode 签名，SmartScreen 可能显示警告。" \
    "" \
    "发布前请核对 SHA256SUMS.txt，并仅在信任源码、提交和构建环境时运行。" \
    "本实验版不启用自动更新；Windows 10/11 原生安装、升级、重启和权限验收尚未完成。" \
    > "$README_FILE"

MANIFEST="$OUTPUT_DIR/BINARY-MANIFEST.json"
jq -n \
    --arg version "$VERSION" \
    --arg mac_arch "$MAC_ARCH" \
    --arg source_commit "$SOURCE_COMMIT" \
    --arg channel "experimental-binary" \
    --arg mac_signature "$MAC_SIGNATURE" \
    --arg mac_identity "${MAC_IDENTITY:-none}" \
    --arg mac_team_id "${MAC_TEAM_ID:-not-set}" \
    --arg mac_gatekeeper "$MAC_GATEKEEPER" \
    --arg windows_signature "unsigned" \
    --arg native_acceptance "not-performed" \
    --arg mac_zip_sha256 "$MAC_SHA256" \
    --arg mac_dmg_sha256 "$MAC_DMG_SHA256" \
    --arg windows_setup_sha256 "$WINDOWS_SETUP_SHA256" \
    --arg windows_portable_sha256 "$WINDOWS_PORTABLE_SHA256" \
    '{
      product: "KEYI 可译",
      version: $version,
      source_commit: $source_commit,
      channel: $channel,
      macos: {
        dmg_artifact: ("KEYI-v" + $version + "-macOS-" + $mac_arch + "-experimental.dmg"),
        artifact: ("KEYI-v" + $version + "-macOS-" + $mac_arch + "-experimental.zip"),
        signature: $mac_signature,
        identity: $mac_identity,
        team_identifier: $mac_team_id,
        gatekeeper: $mac_gatekeeper,
        dmg_sha256: $mac_dmg_sha256,
        sha256: $mac_zip_sha256
      },
      windows: {
        setup_artifact: ("KEYI-v" + $version + "-Windows-x64-experimental-setup.exe"),
        portable_artifact: ("KEYI-v" + $version + "-Windows-x64-experimental-portable.exe"),
        signature: $windows_signature,
        native_acceptance: $native_acceptance,
        setup_sha256: $windows_setup_sha256,
        portable_sha256: $windows_portable_sha256
      },
      auto_update: false
    }' > "$MANIFEST"

echo "实验二进制输出目录：$OUTPUT_DIR"
echo "源码提交：$SOURCE_COMMIT"
echo "SHA256：$CHECKSUMS"
