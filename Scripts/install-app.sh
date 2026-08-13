#!/bin/zsh

set -euo pipefail

SCRIPT_PATH="${(%):-%x}"
ROOT_DIR="${SCRIPT_PATH:A:h:h}"
BUILT_APP="$ROOT_DIR/.build/KEYI 可译.app"
INSTALL_DIR="${KEYI_INSTALL_DIR:-}"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

if [[ -z "$INSTALL_DIR" ]]; then
    echo "请设置 KEYI_INSTALL_DIR 后再安装，例如：KEYI_INSTALL_DIR=/Applications Scripts/install-app.sh" >&2
    exit 2
fi

INSTALLED_APP="${INSTALL_DIR%/}/KEYI 可译.app"

pkill -x HanYi 2>/dev/null || true
if [[ -d "$INSTALLED_APP" ]]; then
    "$LSREGISTER" -u "$INSTALLED_APP" 2>/dev/null || true
fi
source "$ROOT_DIR/Scripts/build-app.sh"

rm -rf "$INSTALLED_APP"
ditto "$BUILT_APP" "$INSTALLED_APP"
codesign --verify --deep --strict --verbose=2 "$INSTALLED_APP"
"$LSREGISTER" -f "$INSTALLED_APP"

echo "$INSTALLED_APP"
