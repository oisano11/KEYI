// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "KEYI",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(name: "KEYI", targets: ["KEYI"])
    ],
    targets: [
        .target(name: "KEYICore"),
        .target(
            name: "KEYIUI",
            dependencies: ["KEYICore"],
            path: "Sources/KEYIUI",
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
            name: "KEYIAppChecks",
            dependencies: ["KEYIUI"],
            path: "Tests/KEYIAppChecks"
        )
    ]
)
