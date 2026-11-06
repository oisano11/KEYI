#!/bin/zsh

set -euo pipefail

ROOT_DIR="${0:A:h:h}"

cd "$ROOT_DIR"

EXPECTED_VERSION="$(sed -nE 's/^[[:space:]]*<Version>([^<]+)<\/Version>$/\1/p' Windows/KEYI.Windows/KEYI.Windows.csproj)"
MAC_SHORT_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' AppBundle/Info.plist)"
MAC_BUILD_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' AppBundle/Info.plist)"
WINDOWS_MANIFEST_VERSION="$(sed -nE 's/.*assemblyIdentity version="([^"]+)".*/\1/p' Windows/KEYI.Windows/app.manifest)"
WINDOWS_MANIFEST_VERSION="${WINDOWS_MANIFEST_VERSION%.0}"

if [[ -z "$EXPECTED_VERSION" || "$MAC_SHORT_VERSION" != "$EXPECTED_VERSION" || "$MAC_BUILD_VERSION" != "$EXPECTED_VERSION" || "$WINDOWS_MANIFEST_VERSION" != "$EXPECTED_VERSION" ]]; then
    echo "版本不一致：macOS short=$MAC_SHORT_VERSION build=$MAC_BUILD_VERSION, Windows project=$EXPECTED_VERSION manifest=$WINDOWS_MANIFEST_VERSION" >&2
    exit 1
fi

echo "发布版本一致：$EXPECTED_VERSION"
swift run KEYICoreChecks
swift run KEYITerminalChecks
swift run KEYIAppChecks
swift run KEYIRegressionChecks
swift run KEYIAppleTranslationProbe --offline-checks
swift build --product KEYITerminal
TERMINAL_BIN_DIR="$(swift build --show-bin-path)"
zsh -n Scripts/Terminal/keyi.zsh
zsh -n Scripts/Terminal/keyi-zsh-draft.zsh
bash -n Scripts/Terminal/keyi.bash
zsh Tests/KEYITerminalFixtures/zsh-checks.zsh
zsh Tests/KEYITerminalFixtures/launcher-checks.zsh "$TERMINAL_BIN_DIR/KEYITerminal"
PYTHONDONTWRITEBYTECODE=1 python3 Tests/KEYITerminalFixtures/zsh-draft-lease-checks.py "$TERMINAL_BIN_DIR/KEYITerminal"
