#!/usr/bin/env bash
# Removes the per-user KEYI input method bundle. User data is left in place
# unless --purge is passed, and the user still removes the input source from
# System Settings.
#
# Usage: Scripts/uninstall-ime.sh [--purge] [--dry-run]
set -euo pipefail

DRY_RUN=0
PURGE=0
for argument in "$@"; do
    case "$argument" in
        --dry-run) DRY_RUN=1 ;;
        --purge) PURGE=1 ;;
        *)
            echo "usage: Scripts/uninstall-ime.sh [--purge] [--dry-run]" >&2
            exit 2
            ;;
    esac
done

INSTALL_DIRECTORY="$HOME/Library/Input Methods"
TARGET_BUNDLE="$INSTALL_DIRECTORY/KEYIIME.app"
# Accept the current identifier and the earlier test build's identifier, but
# only at our exact install path; anything else is left alone.
EXPECTED_BUNDLE_ID="com.keyi.inputmethod.keyi"
LEGACY_BUNDLE_ID="com.keyi.input-method"
USER_DATA="$HOME/Library/Application Support/com.keyi.input-method"
BACKUP_ROOT="$HOME/Library/Application Support/com.keyi.input-method/backups"

if [[ ! -d "$TARGET_BUNDLE" ]]; then
    echo "No installed bundle at $TARGET_BUNDLE"
else
    existing_id="$(plutil -extract CFBundleIdentifier raw \
        "$TARGET_BUNDLE/Contents/Info.plist" 2>/dev/null || true)"
    if [[ "$existing_id" != "$EXPECTED_BUNDLE_ID" \
        && "$existing_id" != "$LEGACY_BUNDLE_ID" ]]; then
        echo "Refusing to remove $TARGET_BUNDLE" >&2
        echo "Existing CFBundleIdentifier is '${existing_id:-<unreadable>}'," >&2
        echo "expected '$EXPECTED_BUNDLE_ID'. Remove it manually if intended." >&2
        exit 1
    fi
    echo "Remove: $TARGET_BUNDLE"
    if [[ "$DRY_RUN" == "0" ]]; then
        STAMP="$(date +%Y%m%d-%H%M%S)"
        mkdir -p "$BACKUP_ROOT"
        mv "$TARGET_BUNDLE" "$BACKUP_ROOT/KEYIIME.app.removed-$STAMP"
        echo "Moved to $BACKUP_ROOT/KEYIIME.app.removed-$STAMP"
    fi
fi

if [[ "$PURGE" == "1" ]]; then
    echo "Remove user data: $USER_DATA"
    if [[ "$DRY_RUN" == "0" && -d "$USER_DATA" ]]; then
        STAMP="$(date +%Y%m%d-%H%M%S)"
        mv "$USER_DATA" "/tmp/com.keyi.input-method.purged-$STAMP"
        echo "Moved user data to /tmp/com.keyi.input-method.purged-$STAMP"
    fi
fi

if [[ "$DRY_RUN" == "1" ]]; then
    echo "--dry-run: no changes made"
else
    echo
    echo "Finish in System Settings -> Keyboard -> Text Input -> Edit..."
fi
