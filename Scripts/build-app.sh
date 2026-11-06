#!/bin/zsh

set -euo pipefail

SCRIPT_PATH="${(%):-%x}"
ROOT_DIR="${SCRIPT_PATH:A:h:h}"
BUILD_DIR="$ROOT_DIR/.build"
APP_DIR="$BUILD_DIR/KEYI 可译.app"

SIGNING_MODE="${KEYI_SIGNING_MODE:-development}"
if [[ "$SIGNING_MODE" != "development" && "$SIGNING_MODE" != "adhoc" && "$SIGNING_MODE" != "distribution" ]]; then
    echo "错误：KEYI_SIGNING_MODE 必须是 development、adhoc 或 distribution。" >&2
    exit 2
fi

SIGNING_IDENTITY=""
if [[ "$SIGNING_MODE" == "adhoc" ]]; then
    SIGNING_IDENTITY="-"
    TIMESTAMP_ARGS=(--timestamp=none)
elif [[ "$SIGNING_MODE" == "distribution" ]]; then
    if [[ -n "${KEYI_SIGNING_IDENTITY:-}" ]]; then
        SIGNING_IDENTITY="$KEYI_SIGNING_IDENTITY"
    else
        SIGNING_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
            | sed -nE 's/^[[:space:]]*[0-9]+\)[[:space:]]+[0-9A-F]+[[:space:]]+"(Developer ID Application: .*)"$/\1/p' \
            | head -n 1 || true)"
    fi
    if [[ -z "$SIGNING_IDENTITY" || "$SIGNING_IDENTITY" != "Developer ID Application: "* ]] \
        || ! security find-identity -v -p codesigning 2>/dev/null \
            | grep -Fq "\"$SIGNING_IDENTITY\""; then
        cat >&2 <<'EOF'
错误：正式分发模式需要 Apple Developer 的 Developer ID Application 证书。
请先在本机安装该有效证书，或设置 KEYI_SIGNING_IDENTITY 为其完整显示名称。
没有证书时请使用默认 development 模式；它只用于本地构建，不能作为受支持的正式分发包。
EOF
        exit 2
    fi
    TIMESTAMP_ARGS=(--timestamp)
else
    # 用本机的 Apple Development 证书（有 Team ID，钥匙串按团队认程序，重装不再弹授权）；
    # 没有时退回 ad-hoc。不取钥匙串里排第一的任意身份：那样会签成别的工具的自签名证书。
    if [[ -n "${KEYI_SIGNING_IDENTITY:-}" ]]; then
        SIGNING_IDENTITY="$KEYI_SIGNING_IDENTITY"
    else
        SIGNING_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
            | sed -nE 's/^[[:space:]]*[0-9]+\)[[:space:]]+[0-9A-F]+[[:space:]]+"(Apple Development: .*)"$/\1/p' \
            | head -n 1 || true)"
        if [[ -z "$SIGNING_IDENTITY" ]]; then
            echo "提示：没找到 Apple Development 证书，改用 ad-hoc 签名；重装后钥匙串可能再次请求授权。" >&2
            SIGNING_IDENTITY="-"
        fi
    fi
    TIMESTAMP_ARGS=(--timestamp=none)
fi

cd "$ROOT_DIR"
swift build -c release --product KEYI
swift build -c release --product KEYITerminal

BIN_DIR="$(swift build -c release --show-bin-path)"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BIN_DIR/KEYI" "$APP_DIR/Contents/MacOS/KEYI"
cp "$BIN_DIR/KEYITerminal" "$APP_DIR/Contents/MacOS/KEYITerminal"
cp "$ROOT_DIR/AppBundle/Info.plist" "$APP_DIR/Contents/Info.plist"
cp "$ROOT_DIR/AppBundle/PkgInfo" "$APP_DIR/Contents/PkgInfo"
cp "$ROOT_DIR/AppBundle/KEYI.icns" "$APP_DIR/Contents/Resources/KEYI.icns"
chmod +x "$APP_DIR/Contents/MacOS/KEYI"
chmod +x "$APP_DIR/Contents/MacOS/KEYITerminal"
mkdir -p "$APP_DIR/Contents/Resources/Terminal"
cp "$ROOT_DIR/Scripts/Terminal/keyi.zsh" "$APP_DIR/Contents/Resources/Terminal/keyi.zsh"
cp "$ROOT_DIR/Scripts/Terminal/keyi-zsh-draft.zsh" "$APP_DIR/Contents/Resources/Terminal/keyi-zsh-draft.zsh"
cp "$ROOT_DIR/Scripts/Terminal/keyi.bash" "$APP_DIR/Contents/Resources/Terminal/keyi.bash"
cp "$ROOT_DIR/Scripts/Terminal/keyi.fish" "$APP_DIR/Contents/Resources/Terminal/keyi.fish"
cp "$ROOT_DIR/Scripts/Terminal/README.md" "$APP_DIR/Contents/Resources/Terminal/README.md"

# 本地模型运行组件：固定版本的官方 llama.cpp macOS 包，校验 sha256 后只取 llama-server 和它依赖的库。
LLAMA_BUILD="b12032"
LLAMA_SHA256="00468fe833eb000b78a748122f5921b6c7b07dc82331a8d0c68196c69cb26382"
LLAMA_ARCHIVE="$BUILD_DIR/vendor/llama-$LLAMA_BUILD-bin-macos-arm64.tar.gz"
LLAMA_SOURCE_DIR="$BUILD_DIR/vendor/llama-$LLAMA_BUILD"
LLAMA_HELPER_DIR="$APP_DIR/Contents/Helpers/llama"
LLAMA_LIBRARIES=(
    libllama-server-impl.dylib
    libllama-common.0.dylib
    libmtmd.0.dylib
    libllama.0.dylib
    libggml.0.dylib
    libggml-cpu.0.dylib
    libggml-blas.0.dylib
    libggml-metal.0.dylib
    libggml-rpc.0.dylib
    libggml-base.0.dylib
)
mkdir -p "$BUILD_DIR/vendor"
if [[ ! -f "$LLAMA_ARCHIVE" ]] \
    || [[ "$(shasum -a 256 "$LLAMA_ARCHIVE" | cut -d ' ' -f 1)" != "$LLAMA_SHA256" ]]; then
    curl --fail --location --silent --show-error \
        --output "$LLAMA_ARCHIVE.partial" \
        "https://github.com/ggml-org/llama.cpp/releases/download/$LLAMA_BUILD/llama-$LLAMA_BUILD-bin-macos-arm64.tar.gz"
    if [[ "$(shasum -a 256 "$LLAMA_ARCHIVE.partial" | cut -d ' ' -f 1)" != "$LLAMA_SHA256" ]]; then
        rm -f "$LLAMA_ARCHIVE.partial"
        echo "错误：llama.cpp $LLAMA_BUILD 安装包的 sha256 不符。" >&2
        exit 1
    fi
    mv "$LLAMA_ARCHIVE.partial" "$LLAMA_ARCHIVE"
    rm -rf "$LLAMA_SOURCE_DIR"
fi
if [[ ! -d "$LLAMA_SOURCE_DIR" ]]; then
    tar -xzf "$LLAMA_ARCHIVE" -C "$BUILD_DIR/vendor"
fi
mkdir -p "$LLAMA_HELPER_DIR"
# 包里的库名是指向带版本号文件的符号链接；按 @rpath 引用的名字复制实体文件。
for LLAMA_FILE in llama-server "${LLAMA_LIBRARIES[@]}"; do
    cp -L "$LLAMA_SOURCE_DIR/$LLAMA_FILE" "$LLAMA_HELPER_DIR/$LLAMA_FILE"
done
# Helpers 里只能放代码，许可证放 Resources。
mkdir -p "$APP_DIR/Contents/Resources/Licenses"
cp "$LLAMA_SOURCE_DIR/LICENSE" "$APP_DIR/Contents/Resources/Licenses/llama.cpp-LICENSE"
for LLAMA_FILE in "${LLAMA_LIBRARIES[@]}"; do
    codesign \
        --force \
        --options runtime \
        "${TIMESTAMP_ARGS[@]}" \
        --sign "$SIGNING_IDENTITY" \
        "$LLAMA_HELPER_DIR/$LLAMA_FILE"
done
# 本地签名没有 Team ID，开启 library validation 时 llama-server 加载不了同包的库。
# 正式分发用同一个 Developer ID 签所有文件，不需要这项例外。
LLAMA_SIGN_ARGS=()
if [[ "$SIGNING_MODE" != "distribution" ]]; then
    LLAMA_ENTITLEMENTS="$BUILD_DIR/llama-server-local.entitlements"
    cat > "$LLAMA_ENTITLEMENTS" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.cs.disable-library-validation</key>
    <true/>
</dict>
</plist>
EOF
    LLAMA_SIGN_ARGS=(--entitlements "$LLAMA_ENTITLEMENTS")
fi
codesign \
    --force \
    --options runtime \
    "${TIMESTAMP_ARGS[@]}" \
    "${LLAMA_SIGN_ARGS[@]}" \
    --sign "$SIGNING_IDENTITY" \
    "$LLAMA_HELPER_DIR/llama-server"

codesign \
    --force \
    --options runtime \
    "${TIMESTAMP_ARGS[@]}" \
    --sign "$SIGNING_IDENTITY" \
    "$APP_DIR/Contents/MacOS/KEYITerminal"
codesign \
    --force \
    --options runtime \
    "${TIMESTAMP_ARGS[@]}" \
    --sign "$SIGNING_IDENTITY" \
    "$APP_DIR"

echo "$APP_DIR"
