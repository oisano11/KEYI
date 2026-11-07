#!/usr/bin/env bash
# Structural checks for a staged KEYI input method bundle. Read-only.
#
# Usage: Scripts/verify-bundle.sh /path/to/KEYIIME.staged
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_BUNDLE="${1:?usage: Scripts/verify-bundle.sh /path/to/KEYIIME.staged}"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_FRAMEWORKS="$APP_CONTENTS/Frameworks"

fail() {
    echo "verify-bundle: $*" >&2
    exit 1
}

[[ -d "$APP_BUNDLE" ]] || fail "missing bundle $APP_BUNDLE"
[[ -x "$APP_MACOS/KEYIIME" ]] || fail "missing executable"
[[ -f "$APP_CONTENTS/Info.plist" ]] || fail "missing Info.plist"
[[ -f "$APP_FRAMEWORKS/librime.1.dylib" ]] || fail "missing librime dylib"
# 语音输入：sherpa-onnx 运行库（dlopen 加载）与 SenseVoice-Small 模型、模型协议原文。
for speech_library in libsherpa-onnx-c-api.dylib libonnxruntime.dylib; do
    [[ -f "$APP_FRAMEWORKS/$speech_library" ]] || fail "missing speech runtime: $speech_library"
done
for sensevoice_file in model.int8.onnx tokens.txt MODEL_LICENSE; do
    [[ -f "$APP_RESOURCES/SenseVoice/$sensevoice_file" ]] || fail "missing SenseVoice file: $sensevoice_file"
done
grep -q "FunASR Model Open Source License Agreement" "$APP_RESOURCES/SenseVoice/MODEL_LICENSE" \
    || fail "SenseVoice model licence is not the upstream text"

# macOS only registers a third-party input method when its identifier contains
# an `.inputmethod.` component that is *not* the final component. The previous
# `com.keyi.input-method` satisfied neither rule and never appeared in any TIS
# enumeration, so both properties are asserted here.
bundle_id="$(plutil -extract CFBundleIdentifier raw "$APP_CONTENTS/Info.plist")"
[[ "$bundle_id" == "com.keyi.inputmethod.keyi" ]] \
    || fail "unexpected CFBundleIdentifier: $bundle_id"

case "$bundle_id" in
    *".inputmethod."*) ;;
    *) fail "CFBundleIdentifier lacks a non-final .inputmethod. segment: $bundle_id" ;;
esac
case "$bundle_id" in
    *.inputmethod|*.inputmethod.) \
        fail "CFBundleIdentifier ends with .inputmethod, which macOS rejects: $bundle_id" ;;
esac

# The signed identifier must match the plist, or the registration handshake and
# the code signature disagree.
signed_id="$(codesign -dv --verbose=4 "$APP_BUNDLE" 2>&1 \
    | awk -F= '/^Identifier=/{print $2}')"
[[ "$signed_id" == "$bundle_id" ]] \
    || fail "signature Identifier ($signed_id) does not match CFBundleIdentifier ($bundle_id)"

min_system="$(plutil -extract LSMinimumSystemVersion raw \
    "$APP_CONTENTS/Info.plist")"
[[ "$min_system" == "15.0" ]] \
    || fail "unexpected LSMinimumSystemVersion: $min_system"

connection="$(plutil -extract InputMethodConnectionName raw \
    "$APP_CONTENTS/Info.plist")"
[[ "$connection" == "com.keyi.inputmethod.keyi_Connection" ]] \
    || fail "unexpected InputMethodConnectionName: $connection"

# The declared input mode must be namespaced under the bundle identifier, and it
# must be the mode the Objective-C controller selects at runtime.
if ! plutil -p "$APP_CONTENTS/Info.plist" | grep -q "$bundle_id.pinyin"; then
    fail "input mode is not namespaced under the bundle identifier"
fi
# The controller must select a mode namespaced under this bundle identifier.
# Read from the compiler-visible source constants rather than the linked binary,
# because the optimizer folds unused string literals out of release builds.
CONTROLLER_SOURCE="$PROJECT_ROOT/Sources/KeyiIMEInputController/KeyiIMEInputController.m"
if [[ -f "$CONTROLLER_SOURCE" ]]; then
    if ! grep -q "$bundle_id.pinyin" "$CONTROLLER_SOURCE"; then
        fail "the controller does not select the declared input mode ($bundle_id.pinyin)"
    fi
    if ! grep -q "$connection" "$CONTROLLER_SOURCE"; then
        fail "the controller does not use the declared connection name ($connection)"
    fi
fi

# Runtime binding check: the shipped executable must resolve its controller and
# session classes from this plist's metadata.
controller_output="$("$APP_MACOS/KEYIIME" --diagnose-bundle 2>&1 || true)"
case "$controller_output" in
    *"controller_resolved=true"*) ;;
    *) fail "--diagnose-bundle did not resolve the controller (output: $controller_output)" ;;
esac
case "$controller_output" in
    *"session=KeyiInputSession"*) ;;
    *) fail "--diagnose-bundle did not resolve the session class" ;;
esac

# A localized display name must exist, so System Settings never shows the raw
# identifier.
if [[ ! -f "$APP_RESOURCES/zh-Hans.lproj/InfoPlist.strings" ]]; then
    fail "missing zh-Hans InfoPlist.strings for the localized mode name"
fi
if ! plutil -p "$APP_RESOURCES/zh-Hans.lproj/InfoPlist.strings" \
    | grep -q "$bundle_id.pinyin"; then
    fail "zh-Hans InfoPlist.strings does not name the input mode"
fi

controller="$(plutil -extract InputMethodServerControllerClass raw \
    "$APP_CONTENTS/Info.plist")"
[[ "$controller" == "KeyiInputController" ]] \
    || fail "unexpected InputMethodServerControllerClass: $controller"

# The default KEYI translation assistant and the upstream Ni input method must
# not be collided with.
for forbidden in "com.keyi.input-translator" \
                 "com.bluuemp.inputmethod.aiime"; do
    if plutil -p "$APP_CONTENTS/Info.plist" | grep -q "$forbidden"; then
        fail "bundle metadata collides with $forbidden"
    fi
done

# No AI model, updater, or local runtime may be shipped with the base.
for forbidden_path in "Models" "Sparkle.framework" \
                     "LocalRuntime" "Helpers"; do
    if [[ -e "$APP_CONTENTS/$forbidden_path" ]]; then
        fail "unexpected packaged component: $forbidden_path"
    fi
done

[[ -f "$APP_RESOURCES/RimeData/keyi_pinyin.schema.yaml" ]] \
    || fail "missing Rime schema"
[[ -f "$APP_RESOURCES/RimeData/keyi_pinyin.dict.yaml" ]] \
    || fail "missing Rime dictionary index"
[[ -f "$APP_RESOURCES/RimeData/keyi_core.dict.yaml" ]] \
    || fail "missing KEYI core dictionary"
# The active KEYI schema keeps its stable identifier but now imports the
# vendored 雾凇拼音 corpus. Assert every table so a partial copy cannot silently
# fall back to the old compact dictionary.
[[ -f "$APP_RESOURCES/RimeData/rime_ice/rime_ice.dict.yaml" ]] \
    || fail "missing rime-ice dictionary index"
# The bundled tables' upstream commit and date: dictionary updates compare against it,
# and user-directory copies that are not newer yield to the bundle at launch.
grep -q '"commit"' "$APP_RESOURCES/RimeData/rime_ice/KEYI-VERSION.json" 2>/dev/null \
    || fail "missing rime-ice version record"
for rime_ice_table in 8105 base ext tencent others; do
    [[ -f "$APP_RESOURCES/RimeData/rime_ice/cn_dicts/$rime_ice_table.dict.yaml" ]] \
        || fail "missing rime-ice table: $rime_ice_table"
done
if grep -qE '^[[:space:]]*-[[:space:]]+.*pinyin_simp' \
    "$PROJECT_ROOT/resources/rime/keyi_pinyin.dict.yaml"; then
    fail "legacy pinyin_simp is still in the active import chain"
fi
# Mixed English input: KEYI's English schema and table, the SCOWL words (with
# their copyright notice, which the licence requires) and rime-ice's en_ext.
for english_data in "keyi_english.schema.yaml" "keyi_english.dict.yaml" \
                    "english/scowl.dict.yaml" "english/en_ext.dict.yaml" \
                    "english/LICENSE.scowl"; do
    [[ -f "$APP_RESOURCES/RimeData/$english_data" ]] \
        || fail "missing English data: $english_data"
done
grep -q "Kevin Atkinson" "$APP_RESOURCES/RimeData/english/LICENSE.scowl" \
    || fail "SCOWL copyright notice is incomplete"
# The legacy pinyin_simp table was removed; it must not come back into the bundle.
for legacy_data in "pinyin_simp.dict.yaml" "LICENSE.pinyin-simp"; do
    [[ ! -e "$APP_RESOURCES/RimeData/$legacy_data" ]] \
        || fail "legacy data shipped again: $legacy_data"
done
[[ -f "$APP_RESOURCES/RimeData/LICENSE.rime-ice-GPL-3.0" ]] \
    || fail "missing rime-ice licence"
[[ -f "$APP_RESOURCES/RimeData/CREDITS.rime-ice.md" ]] \
    || fail "missing rime-ice credits"
grep -q "GNU GENERAL PUBLIC LICENSE" \
    "$APP_RESOURCES/RimeData/LICENSE.rime-ice-GPL-3.0" \
    || fail "rime-ice licence is not the upstream GPL text"
grep -q "iDvel" "$APP_RESOURCES/RimeData/CREDITS.rime-ice.md" \
    || fail "rime-ice credits do not identify the upstream dataset"
[[ -f "$APP_RESOURCES/librime-LICENSE.txt" ]] \
    || fail "missing librime licence"
[[ -f "$APP_RESOURCES/THIRD_PARTY_NOTICES.md" ]] \
    || fail "missing third-party notices"
[[ -f "$APP_RESOURCES/SOURCES.md" ]] \
    || fail "missing provenance manifest"
[[ -f "$APP_RESOURCES/KeyiInputLogo.pdf" ]] \
    || fail "missing input mode icon"
[[ -f "$APP_RESOURCES/KEYI.icns" ]] \
    || fail "missing app icon (the KEYI hummingbird)"
# A full-page PDF makes a huge, blank row in the input menu.
LOGO_SIZE="$(sips -g pixelWidth -g pixelHeight "$APP_RESOURCES/KeyiInputLogo.pdf" 2>/dev/null \
    | awk '/pixel(Width|Height)/{printf "%d ", $2}')"
[[ "$LOGO_SIZE" == "16 16 " ]] \
    || fail "input mode icon must be a 16x16 page (got ${LOGO_SIZE:-unknown})"
# macOS draws input method icons as templates (alpha only): an opaque square shows
# as a solid block. The icon must have clear pixels (around the hummingbird and the gap between wing and body).
LOGO_PNG="$(mktemp -t keyi-logo).png"
sips -s format png -Z 64 "$APP_RESOURCES/KeyiInputLogo.pdf" --out "$LOGO_PNG" >/dev/null 2>&1 \
    || fail "input mode icon could not be rendered"
LOGO_CLEAR="$(/usr/bin/python3 - "$LOGO_PNG" <<'PY'
import struct, sys, zlib
data = open(sys.argv[1], 'rb').read()
pos, idat, width, height, colour = 8, b'', 0, 0, 0
while pos < len(data):
    length, kind = struct.unpack('>I4s', data[pos:pos + 8])
    body = data[pos + 8:pos + 8 + length]
    if kind == b'IHDR':
        width, height, _, colour = struct.unpack('>IIBB', body[:10])
    elif kind == b'IDAT':
        idat += body
    pos += 12 + length
if colour != 6:
    print(0); sys.exit()
raw, stride, rows, prev = zlib.decompress(idat), width * 4, [], bytearray(width * 4)
for y in range(height):
    f, line = raw[y * (stride + 1)], bytearray(raw[y * (stride + 1) + 1:(y + 1) * (stride + 1)])
    for i in range(stride):
        a = line[i - 4] if i >= 4 else 0
        b = prev[i]
        c = prev[i - 4] if i >= 4 else 0
        if f == 1: line[i] = (line[i] + a) & 255
        elif f == 2: line[i] = (line[i] + b) & 255
        elif f == 3: line[i] = (line[i] + (a + b) // 2) & 255
        elif f == 4:
            p = a + b - c; pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
            line[i] = (line[i] + (a if pa <= pb and pa <= pc else b if pb <= pc else c)) & 255
    rows.append(line); prev = line
print(sum(1 for r in rows for x in range(width) if r[x * 4 + 3] < 26))
PY
)"
rm -f "$LOGO_PNG"
[[ "${LOGO_CLEAR:-0}" -gt 200 ]] \
    || fail "input mode icon has no transparent cut-out; the menu would show a solid block (clear pixels: ${LOGO_CLEAR:-0})"

# The executable and bundle must stay distinct from the KEYI translation
# assistant, which is installed as KEYI.app with its own bundle identifier.
if [[ -e "$APP_MACOS/KEYI" ]]; then
    fail "bundle must not ship an executable named KEYI"
fi
if [[ "$(basename "$APP_BUNDLE")" == "KEYI.app" ]]; then
    fail "input method bundle must not be named KEYI.app"
fi
for shipped_licence in librime-LICENSE.txt ni-input-method-LICENSE.txt; do
    if ! grep -qiE "BSD|MIT|Permission is hereby granted|Redistribution" \
        "$APP_RESOURCES/$shipped_licence"; then
        fail "$shipped_licence does not look like a licence text"
    fi
done

# Every static component linked into librime ships its own licence text, taken
# from the pinned upstream revision rather than rewritten here.
LICENCE_DIR="$APP_RESOURCES/licenses"
declare -a required_licences=(
    "glog-BSD3.txt"
    "leveldb-BSD3.txt"
    "marisa-trie-dual.txt"
    "opencc-Apache2.txt"
    "yaml-cpp-MIT.txt"
    "boost-BSL1.txt"
    "darts-clone-BSD2.txt"
    "sherpa-onnx-Apache2.txt"
    "onnxruntime-MIT.txt"
)
for licence in "${required_licences[@]}"; do
    [[ -f "$LICENCE_DIR/$licence" ]] \
        || fail "missing static dependency licence: $licence"
done

# Each licence must look like the licence it claims to be, and none may be a
# placeholder written by hand.
licence_expectation() {
    case "$1" in
        *BSD3*) echo "Redistribution and use in source and binary forms" ;;
        *BSD2*) echo "Redistribution and use in source and binary forms" ;;
        *Apache2*) echo "Apache License" ;;
        *MIT*) echo "Permission is hereby granted" ;;
        *BSL1*) echo "Boost Software License" ;;
        *dual*) echo "BSD-2-Clause" ;;
        *) echo "" ;;
    esac
}
for licence in "${required_licences[@]}"; do
    expected="$(licence_expectation "$licence")"
    [[ -n "$expected" ]] || fail "no expectation for $licence"
    if ! grep -qF "$expected" "$LICENCE_DIR/$licence"; then
        fail "$licence does not contain the expected licence text"
    fi
done
# marisa-trie is dual licensed; the BSD-2-Clause branch is the one this card
# relies on, so both the choice and the alternative must stay visible.
if ! grep -q "BSD-2-Clause" "$LICENCE_DIR/marisa-trie-dual.txt"; then
    fail "marisa-trie licence does not state the BSD-2-Clause branch"
fi

# Keep unrelated Ni/AI data and generated test fixtures out of the bundle. The
# mature rime-ice corpus has its own mixed upstream attribution (including the
# CC BY and LGPL sources documented in THIRD_PARTY_NOTICES.md); those declared
# data files are intentionally allowed and ship with their notices.
for forbidden_data in "ni_modern.dict.yaml" "essay-zh-hans.txt" \
                      "ni_supplement.dict.yaml" "emoji.dict.yaml" \
                      "symbols.dict.yaml" "candidate_regression.tsv" \
                      "LICENSE.essay-simp-LGPL-3.0" \
                      "LICENSE.ni-modern-CC-BY-4.0"; do
    if [[ -e "$APP_RESOURCES/RimeData/$forbidden_data" ]]; then
        fail "unexpected data shipped: $forbidden_data"
    fi
done

# Dynamic dependencies must resolve inside the bundle or from the system.
dependency_failure=0
while read -r dependency; do
    case "$dependency" in
        @rpath/librime.1.dylib) ;;
        /usr/lib/*|/System/Library/*) ;;
        *) dependency_failure=1 ;;
    esac
done < <(otool -L "$APP_MACOS/KEYIIME" | tail -n +2 | awk '{print $1}')
[[ "$dependency_failure" == "0" ]] \
    || fail "unexpected dynamic dependency (see otool -L)"

if ! otool -l "$APP_MACOS/KEYIIME" | grep -q "@loader_path/../Frameworks"; then
    fail "missing @loader_path/../Frameworks rpath"
fi

echo "verify-bundle: OK ($APP_BUNDLE)"
