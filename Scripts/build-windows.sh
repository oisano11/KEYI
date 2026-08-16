#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
LOCAL_DOTNET_DIR="$ROOT_DIR/.tools/dotnet"
OUTPUT_DIR="$ROOT_DIR/.build/windows"
PUBLISH_DIR="$OUTPUT_DIR/app"
DOTNET_ARTIFACTS_DIR="$OUTPUT_DIR/dotnet-artifacts"
VERIFY_DIR="$(mktemp -d)"
trap 'rm -rf "$VERIFY_DIR"' EXIT

has_dotnet_8_runtime() {
  "$1" --list-runtimes 2>/dev/null | grep -q '^Microsoft.NETCore.App 8\.'
}

if command -v dotnet >/dev/null 2>&1 && has_dotnet_8_runtime "$(command -v dotnet)"; then
  DOTNET_COMMAND="$(command -v dotnet)"
elif [[ -x "$LOCAL_DOTNET_DIR/dotnet" ]] && has_dotnet_8_runtime "$LOCAL_DOTNET_DIR/dotnet"; then
  DOTNET_COMMAND="$LOCAL_DOTNET_DIR/dotnet"
else
  curl -fsSL https://dot.net/v1/dotnet-install.sh -o "$VERIFY_DIR/dotnet-install.sh"
  /bin/bash "$VERIFY_DIR/dotnet-install.sh" --channel 8.0 --install-dir "$LOCAL_DOTNET_DIR"
  DOTNET_COMMAND="$LOCAL_DOTNET_DIR/dotnet"
fi

export DOTNET_CLI_TELEMETRY_OPTOUT=1
export DOTNET_NOLOGO=1
APP_VERSION="$("$DOTNET_COMMAND" msbuild \
  "$ROOT_DIR/Windows/KEYI.Windows/KEYI.Windows.csproj" \
  -getProperty:Version)"
if [[ ! "$APP_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "错误：Windows 版本号无效：$APP_VERSION" >&2
  exit 1
fi

rm -rf "$OUTPUT_DIR"
"$DOTNET_COMMAND" run --project "$ROOT_DIR/Windows/KEYI.CoreChecks/KEYI.CoreChecks.csproj" -c Release
"$DOTNET_COMMAND" publish "$ROOT_DIR/Windows/KEYI.Windows/KEYI.Windows.csproj" \
  -c Release \
  -r win-x64 \
  --self-contained true \
  --artifacts-path "$DOTNET_ARTIFACTS_DIR" \
  -p:PublishSingleFile=true \
  -p:DebugSymbols=false \
  -p:DebugType=None \
  -o "$PUBLISH_DIR"

python3 "$ROOT_DIR/Scripts/inspect-pe-version.py" \
  --expected-version "$APP_VERSION" \
  "$PUBLISH_DIR/KEYI.exe"

if ! command -v makensis >/dev/null 2>&1; then
  echo "错误：缺少 makensis。macOS 可执行 brew install nsis。" >&2
  exit 1
fi
if command -v 7zz >/dev/null 2>&1; then
  SEVEN_ZIP_COMMAND="$(command -v 7zz)"
elif command -v 7z >/dev/null 2>&1; then
  SEVEN_ZIP_COMMAND="$(command -v 7z)"
else
  echo "错误：缺少 7zz/7z。macOS 可执行 brew install sevenzip。" >&2
  exit 1
fi

NSIS_APP_FILE="$PUBLISH_DIR/KEYI.exe"
NSIS_OUTPUT_DIR="$OUTPUT_DIR"
if command -v cygpath >/dev/null 2>&1; then
  NSIS_APP_FILE="$(cygpath -w "$NSIS_APP_FILE")"
  NSIS_OUTPUT_DIR="$(cygpath -w "$NSIS_OUTPUT_DIR")"
fi

makensis \
  -DAPP_FILE="$NSIS_APP_FILE" \
  -DOUTPUT_DIR="$NSIS_OUTPUT_DIR" \
  -DAPP_VERSION="$APP_VERSION" \
  "$ROOT_DIR/Windows/Installer/KEYI.nsi"

python3 "$ROOT_DIR/Scripts/inspect-pe-version.py" \
  --expected-version "$APP_VERSION" \
  "$OUTPUT_DIR/KEYI-Setup.exe"

EXTRACT_DIR="$VERIFY_DIR/extracted"
"$SEVEN_ZIP_COMMAND" x \
  -y \
  "-o$EXTRACT_DIR" \
  "$OUTPUT_DIR/KEYI-Setup.exe" >/dev/null
EXTRACTED_APP="$EXTRACT_DIR/KEYI.exe"
if [[ ! -f "$EXTRACTED_APP" ]]; then
  echo "错误：安装器解包后缺少 KEYI.exe。" >&2
  exit 1
fi

python3 "$ROOT_DIR/Scripts/inspect-pe-version.py" \
  --expected-version "$APP_VERSION" \
  "$EXTRACTED_APP"

PUBLISHED_APP_SHA256="$(shasum -a 256 "$PUBLISH_DIR/KEYI.exe" | awk '{print $1}')"
EXTRACTED_APP_SHA256="$(shasum -a 256 "$EXTRACTED_APP" | awk '{print $1}')"
if [[ "$PUBLISHED_APP_SHA256" != "$EXTRACTED_APP_SHA256" ]]; then
  echo "错误：安装器内嵌 KEYI.exe 与本次发布产物 SHA-256 不一致。" >&2
  exit 1
fi

(
  cd "$OUTPUT_DIR"
  shasum -a 256 KEYI-Setup.exe > KEYI-Setup.exe.sha256
)

file "$PUBLISH_DIR/KEYI.exe"
file "$OUTPUT_DIR/KEYI-Setup.exe"
echo "程序版本：$APP_VERSION"
echo "程序 SHA-256：$PUBLISHED_APP_SHA256"
echo "内嵌程序 SHA-256：$EXTRACTED_APP_SHA256"
echo "Windows 产物：$PUBLISH_DIR/KEYI.exe"
echo "Windows 安装器：$OUTPUT_DIR/KEYI-Setup.exe"
echo "安装器校验：$OUTPUT_DIR/KEYI-Setup.exe.sha256"
