#!/usr/bin/env bash
# 语音输入的本地识别（契约「2026-11-07 语音输入最小版授权」补充）：下载固定版本的 sherpa-onnx
# 运行库与 SenseVoice-Small 模型，校验 sha256 后解压到 .build/vendor。已下载且校验相符就不再下载。
# 输入法运行时从不联网；只有构建时用这个脚本取文件。
#
# Usage: Scripts/fetch-sensevoice.sh   （打印两行：运行库 lib 目录、模型目录）
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENDOR="$PROJECT_ROOT/.build/vendor"

SHERPA_VERSION="v2.0.1"
SHERPA_NAME="sherpa-onnx-$SHERPA_VERSION-osx-arm64-shared"
SHERPA_SHA256="5e874d3c9b3d6b8c71f7c09e3a9fb9ae846c3009129d302b398d1f7aedb69f84"
SHERPA_URL="https://github.com/k2-fsa/sherpa-onnx/releases/download/$SHERPA_VERSION/$SHERPA_NAME.tar.bz2"

MODEL_NAME="sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2024-07-17"
MODEL_SHA256="7d1efa2138a65b0b488df37f8b89e3d91a60676e416f515b952358d83dfd347e"
MODEL_URL="https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/$MODEL_NAME.tar.bz2"

fetch() {
    local url="$1" archive="$2" sha="$3" directory="$4"
    if [[ ! -f "$archive" ]] || [[ "$(shasum -a 256 "$archive" | cut -d ' ' -f 1)" != "$sha" ]]; then
        echo "fetch-sensevoice: downloading $(basename "$archive")" >&2
        curl --fail --location --silent --show-error --output "$archive.partial" "$url"
        if [[ "$(shasum -a 256 "$archive.partial" | cut -d ' ' -f 1)" != "$sha" ]]; then
            rm -f "$archive.partial"
            echo "fetch-sensevoice: sha256 mismatch for $(basename "$archive")" >&2
            exit 1
        fi
        mv "$archive.partial" "$archive"
        rm -rf "$directory"
    fi
    if [[ ! -d "$directory" ]]; then
        tar -xjf "$archive" -C "$VENDOR"
    fi
}

mkdir -p "$VENDOR"
fetch "$SHERPA_URL" "$VENDOR/$SHERPA_NAME.tar.bz2" "$SHERPA_SHA256" "$VENDOR/$SHERPA_NAME"
fetch "$MODEL_URL" "$VENDOR/$MODEL_NAME.tar.bz2" "$MODEL_SHA256" "$VENDOR/$MODEL_NAME"
for required in "$VENDOR/$SHERPA_NAME/lib/libsherpa-onnx-c-api.dylib" \
                "$VENDOR/$SHERPA_NAME/lib/libonnxruntime.dylib" \
                "$VENDOR/$MODEL_NAME/model.int8.onnx" \
                "$VENDOR/$MODEL_NAME/tokens.txt"; do
    [[ -f "$required" ]] || { echo "fetch-sensevoice: missing $required" >&2; exit 1; }
done
echo "$VENDOR/$SHERPA_NAME/lib"
echo "$VENDOR/$MODEL_NAME"
