#!/usr/bin/env bash
# Installs the staged KEYI input method bundle for the current user.
#
# This never runs automatically and never enables or selects the input source;
# the user finishes with System Settings. Pass --dry-run to only print actions.
#
# Usage: Scripts/install-ime.sh [--dry-run] [debug|release]
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Bundle identifiers must contain a non-final `.inputmethod.` segment before
# macOS will register the input method. The build uses the new form; the
# previous identifier is still accepted *only* at our exact install path so an
# existing test install can be upgraded instead of blocking.
EXPECTED_BUNDLE_ID="com.keyi.inputmethod.keyi"
LEGACY_BUNDLE_ID="com.keyi.input-method"
UNINSTALL_SCRIPT="$PROJECT_ROOT/Scripts/uninstall-ime.sh"
DRY_RUN=0
CONFIGURATION="debug"
for argument in "$@"; do
    case "$argument" in
        --dry-run) DRY_RUN=1 ;;
        debug|release) CONFIGURATION="$argument" ;;
        *)
            echo "usage: Scripts/install-ime.sh [--dry-run] [debug|release]" >&2
            exit 2
            ;;
    esac
done

SOURCE_BUNDLE="$PROJECT_ROOT/.build/KEYIIME.staged"
INSTALL_DIRECTORY="$HOME/Library/Input Methods"
TARGET_BUNDLE="$INSTALL_DIRECTORY/KEYIIME.app"
BACKUP_ROOT="$HOME/Library/Application Support/com.keyi.input-method/backups"

if [[ ! -d "$SOURCE_BUNDLE" ]]; then
    echo "No staged bundle at $SOURCE_BUNDLE." >&2
    echo "Build first: Scripts/build-ime.sh $CONFIGURATION" >&2
    exit 1
fi

# Never install a bundle that is not the KEYI input method: the target path is
# inside the user's Input Methods directory, where a wrong bundle could shadow
# another input method.
if ! "$PROJECT_ROOT/Scripts/verify-bundle.sh" "$SOURCE_BUNDLE" >/dev/null; then
    echo "Refusing to install: staged bundle failed verification." >&2
    echo "Run Scripts/verify-bundle.sh $SOURCE_BUNDLE for details." >&2
    exit 1
fi

echo "Source: $SOURCE_BUNDLE"
echo "Target: $TARGET_BUNDLE"
echo "Note:   the input source is not enabled or selected automatically."

if [[ "$DRY_RUN" == "1" ]]; then
    echo "--dry-run: no changes made"
    exit 0
fi

if [[ -d "$TARGET_BUNDLE" ]]; then
    # Only replace our own bundle. Anything else at this path is left alone so
    # the script cannot clobber an unrelated input method.
    existing_id="$(plutil -extract CFBundleIdentifier raw \
        "$TARGET_BUNDLE/Contents/Info.plist" 2>/dev/null || true)"
    if [[ "$existing_id" != "$EXPECTED_BUNDLE_ID" \
        && "$existing_id" != "$LEGACY_BUNDLE_ID" ]]; then
        echo "Refusing to overwrite $TARGET_BUNDLE" >&2
        echo "Existing CFBundleIdentifier is '${existing_id:-<unreadable>}'," >&2
        echo "expected '$EXPECTED_BUNDLE_ID' (or the previous" >&2
        echo "'$LEGACY_BUNDLE_ID' test build at this exact path)." >&2
        exit 1
    fi
    if [[ "$existing_id" == "$LEGACY_BUNDLE_ID" ]]; then
        echo "Upgrading the earlier test build ($LEGACY_BUNDLE_ID) in place."
    fi
    # Replace the existing copy only after moving it aside, so a failed install
    # never leaves the user without a working input method.
    STAMP="$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$BACKUP_ROOT"
    BACKUP="$BACKUP_ROOT/KEYIIME.app.$STAMP"
    echo "Existing install found; moving it to $BACKUP"
    mv "$TARGET_BUNDLE" "$BACKUP"
fi

mkdir -p "$INSTALL_DIRECTORY"
ditto "$SOURCE_BUNDLE" "$TARGET_BUNDLE"
chmod +x "$TARGET_BUNDLE/Contents/MacOS/KEYIIME"

LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
"$LSREGISTER" -f "$TARGET_BUNDLE" >/dev/null 2>&1 || true

# LaunchServices registration alone leaves Text Input Sources unable to
# enumerate the installed bundle: on this host a fresh process saw no KEYI
# source at all until `TISRegisterInputSource` ran against the exact installed
# path, which is what the upstream Ni installer does from its shipped
# executable. Only registration happens here. The input source is never
# enabled, never selected, and never made the default.
"$TARGET_BUNDLE/Contents/MacOS/KEYIIME" --register-installed

echo
echo "Installed. Finish in System Settings:"
echo "  1. System Settings -> Keyboard -> Text Input -> Edit..."
echo "  2. Add input source -> Chinese, Simplified -> KEYI 输入法"
echo "  3. If it does not appear, log out and back in, then retry."
echo
echo "To remove it again: $UNINSTALL_SCRIPT"
