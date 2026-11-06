#!/usr/bin/env bash
# Runs every automated check for the KEYI input method:
#   1. engine smoke test against a throwaway Rime user directory
#   2. automatic translation checks driving the production controller
#   3. bundle build and structural verification
#   4. InputMethodKit session diagnostics with a mock text client
#
# None of these install or select an input source.
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_ROOT"

RIME_USER_DIR="$(mktemp -d -t keyi-ime-user)"
trap 'rm -rf "$RIME_USER_DIR"' EXIT

echo "== 1/4 Engine smoke test =="
BIN_PATH="$(swift build --product keyi-smoke --show-bin-path)"
swift build --product keyi-smoke >/dev/null
DYLD_LIBRARY_PATH="$PROJECT_ROOT/Vendor/librime/lib" \
    "$BIN_PATH/keyi-smoke" \
    "$PROJECT_ROOT/resources/rime" \
    "$RIME_USER_DIR"

echo
echo "== 2/4 Automatic translation checks =="
# Drives the production controller with a stub client. It never contacts the
# translation service, so the result is deterministic with or without the
# companion app running.
swift build --target KeyiAutomaticTranslationChecks >/dev/null
AUTOMATIC_BIN_PATH="$(swift build --target KeyiAutomaticTranslationChecks --show-bin-path)"
"$AUTOMATIC_BIN_PATH/KeyiAutomaticTranslationChecks"

echo
echo "== 3/4 Bundle build and verification =="
"$PROJECT_ROOT/Scripts/build-ime.sh" debug | tail -5

echo
echo "== 4/4 Input session diagnostics =="
# The diagnostics are pinned to a throwaway Rime directory so running the suite
# never writes into the live user dictionary.
# Automatic translation is disabled for this target: it drives the session with
# a stub client faster than a user could, and a live companion service would
# rewrite the stub documents asynchronously between assertions. The production
# controller is covered by the automatic translation checks above, and the
# session wiring with automatic translation on by the second group below.
DIAGNOSTICS_USER_DIR="$RIME_USER_DIR/diagnostics"
mkdir -p "$DIAGNOSTICS_USER_DIR"
"$PROJECT_ROOT/.build/KEYIIME.staged/Contents/MacOS/KEYIIME" --diagnose-bundle
# Dictionary updates are test-built by the installed input method before they are
# used: the bundled tables must pass, a truncated table must not.
STAGED_TABLES="$RIME_USER_DIR/staged-tables"
mkdir -p "$STAGED_TABLES"
cp "$PROJECT_ROOT"/resources/rime/rime_ice/cn_dicts/{8105,base,ext,tencent,others}.dict.yaml "$STAGED_TABLES/"
"$PROJECT_ROOT/.build/KEYIIME.staged/Contents/MacOS/KEYIIME" --verify-dictionary "$STAGED_TABLES"
head -c 2000 "$PROJECT_ROOT/resources/rime/rime_ice/cn_dicts/base.dict.yaml" > "$STAGED_TABLES/base.dict.yaml"
if "$PROJECT_ROOT/.build/KEYIIME.staged/Contents/MacOS/KEYIIME" --verify-dictionary "$STAGED_TABLES" >/dev/null 2>&1; then
    echo "FAIL: a truncated base table passed the dictionary test build"
    exit 1
fi
echo "PASS: a truncated base table fails the dictionary test build"
KEYI_IME_USER_DATA_DIR="$DIAGNOSTICS_USER_DIR" \
    KEYI_IME_DISABLE_AUTOMATIC_TRANSLATION=1 \
    "$PROJECT_ROOT/.build/KEYIIME.staged/Contents/MacOS/KEYIIME" --diagnose-session

# Second group: automatic translation ON, with a fake translator ("EN(<source>)")
# injected into the session. The session only accepts the fake translator when
# KEYI_IME_DIAGNOSTIC_FAKE_TRANSLATION=1, which only this script sets, so the
# installed input method cannot enable it by accident. Real Rime, mock client.
TRANSLATION_DIAGNOSTICS_USER_DIR="$RIME_USER_DIR/diagnostics-translation"
mkdir -p "$TRANSLATION_DIAGNOSTICS_USER_DIR"
KEYI_IME_USER_DATA_DIR="$TRANSLATION_DIAGNOSTICS_USER_DIR" \
    KEYI_IME_DIAGNOSTIC_FAKE_TRANSLATION=1 \
    "$PROJECT_ROOT/.build/KEYIIME.staged/Contents/MacOS/KEYIIME" --diagnose-session-translation

echo
echo "All checks passed."
