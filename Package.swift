// swift-tools-version: 6.0

import PackageDescription

// 翻译服务线协议与客户端在共享包 Packages/KEYITranslationClient，
// KEYI 拼音输入法（IME/ 包）依赖同一个包，两边不再各自复制。
let translationClient: Target.Dependency = .product(
    name: "KEYITranslationClient",
    package: "KEYITranslationClient"
)

let package = Package(
    name: "KEYI",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(name: "KEYI", targets: ["KEYI"]),
        .executable(name: "KEYITerminal", targets: ["KEYITerminal"])
    ],
    dependencies: [
        .package(path: "Packages/KEYITranslationClient")
    ],
    targets: [
        .target(
            name: "KEYICore",
            exclude: ["SPEC.md"]
        ),
        .target(
            name: "KEYITranslationService",
            dependencies: ["KEYICore", translationClient],
            exclude: ["SPEC.md"]
        ),
        .target(
            name: "KEYIUI",
            dependencies: ["KEYICore", translationClient, "KEYITranslationService"],
            path: "Sources/KEYIUI",
            exclude: ["SPEC.md", "Writeback-SPEC.md", "LocalModel-SPEC.md"],
            swiftSettings: [
                // 仅 debug 构建开启测试性导出，供 KEYIAppChecks 以 @testable
                // 导入；应用包不会被其他包作为依赖引用，unsafeFlags 无副作用。
                .unsafeFlags(
                    ["-enable-testing"],
                    .when(configuration: .debug)
                )
            ]
        ),
        .executableTarget(
            name: "KEYI",
            dependencies: ["KEYIUI"],
            linkerSettings: [
                .linkedFramework("ApplicationServices"),
                .linkedFramework("Carbon"),
                .linkedFramework("Translation")
            ]
        ),
        .executableTarget(
            name: "KEYICoreChecks",
            dependencies: ["KEYICore"],
            path: "Tests/KEYICoreChecks"
        ),
        .executableTarget(
            name: "KEYITerminal",
            dependencies: ["KEYICore", "KEYIUI"],
            path: "Sources/KEYITerminal",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Translation")
            ]
        ),
        .executableTarget(
            name: "KEYITerminalChecks",
            dependencies: ["KEYICore"],
            path: "Tests/KEYITerminalChecks"
        ),
        .executableTarget(
            name: "KEYITranslationServiceCLI",
            dependencies: ["KEYIUI", "KEYITranslationService", translationClient],
            path: "Sources/KEYITranslationServiceCLI"
        ),
        .executableTarget(
            name: "KEYIAppChecks",
            dependencies: ["KEYIUI", "KEYITranslationService", translationClient],
            path: "Tests/KEYIAppChecks"
        ),
        .executableTarget(
            name: "KEYIRegressionChecks",
            dependencies: ["KEYIUI"],
            path: "Tests/KEYIRegressionChecks"
        ),
        .executableTarget(
            name: "KEYIAppleTranslationProbe",
            dependencies: ["KEYICore", translationClient, "KEYITranslationService", "KEYIUI"],
            path: "Tests/KEYIAppleTranslationProbe"
        )
    ]
)
