// swift-tools-version: 6.0

import PackageDescription

// KEYI 翻译服务的线协议、客户端与输入法侧薄封装。KEYI 可译伴随应用（服务端，
// 仓库根包）与 KEYI 拼音输入法（客户端，IME/ 包）都依赖本包，共用同一份源码。
let package = Package(
    name: "KEYITranslationClient",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(name: "KEYITranslationClient", targets: ["KEYITranslationClient"])
    ],
    targets: [
        .target(name: "KEYITranslationClient")
    ]
)
