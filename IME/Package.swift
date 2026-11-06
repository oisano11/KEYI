// swift-tools-version: 6.0

import PackageDescription
import Foundation

// Include/link flags are passed to the compiler verbatim, so a relative path is
// resolved against whatever working directory the toolchain happens to use.
// Older toolchains ran with the package root as cwd; newer ones do not, which
// made `-I Vendor/librime/include` stop resolving. Anchor both flags to the
// package directory so the build does not depend on the caller's cwd.
let packageRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().path
let librimeInclude = "\(packageRoot)/Vendor/librime/include"
let librimeLib = "\(packageRoot)/Vendor/librime/lib"

// 翻译服务线协议与客户端：与 KEYI 可译伴随应用（仓库根包）共用
// ../Packages/KEYITranslationClient，不再在本包里保留副本。
let translationClient: Target.Dependency = .product(
    name: "KEYITranslationClient",
    package: "KEYITranslationClient"
)

let package = Package(
    name: "KeyiIME",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        .executable(name: "KEYIIME", targets: ["KeyiIME"]),
        .executable(name: "keyi-smoke", targets: ["KeyiSmokeTest"]),
        .executable(name: "keyi-native-probe", targets: ["KeyiNativeProbe"]),
    ],
    dependencies: [
        .package(path: "../Packages/KEYITranslationClient"),
    ],
    targets: [
        .target(
            name: "KeyiIMECore",
            cxxSettings: [
                .unsafeFlags(["-std=c++17"]),
                .unsafeFlags(["-I", librimeInclude]),
            ]
        ),
        .target(
            name: "KeyiIMEBridge",
            dependencies: ["KeyiIMECore"],
            cxxSettings: [
                .unsafeFlags(["-std=c++17"]),
            ]
        ),
        .target(
            name: "KeyiIMEInputController",
            cSettings: [
                // InputMethodKit owns controller instances. Keeping this
                // narrow compatibility layer under Objective-C MRC avoids
                // Swift ARC participating in that legacy lifecycle.
                .unsafeFlags(["-fno-objc-arc"]),
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("InputMethodKit"),
                .linkedFramework("OSLog"),
            ]
        ),
        .target(
            name: "KeyiIMEDiagnostics",
            dependencies: ["KeyiIMEBridge"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("InputMethodKit"),
            ]
        ),
        // 自动翻译：KEYI 拼音确认中文后经 AF_UNIX socket 调用 KEYI 可译伴随服务。
        // 本 target 只含客户端文本能力接口与自动翻译控制器（线协议客户端与薄封装
        // 来自共享包），不加载模型、不碰凭据。
        .target(
            name: "KeyiIMETranslation",
            dependencies: [translationClient],
            exclude: ["SPEC.md"],
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ],
            linkerSettings: [
                .linkedFramework("InputMethodKit"),
                .linkedFramework("Carbon"),
            ]
        ),
        .target(
            name: "KeyiIMEKit",
            dependencies: [
                "KeyiIMEBridge",
                "KeyiIMEInputController",
                "KeyiIMETranslation",
                translationClient,
            ],
            exclude: ["SPEC.md"],
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("InputMethodKit"),
                .linkedFramework("OSLog"),
            ]
        ),
        .executableTarget(
            name: "KeyiIME",
            dependencies: [
                "KeyiIMEKit",
                "KeyiIMEDiagnostics",
                "KeyiIMEBridge",
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("InputMethodKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("OSLog"),
                .unsafeFlags([
                    "-L", librimeLib,
                    "-lrime",
                    "-Xlinker", "-rpath",
                    "-Xlinker", "@loader_path/../Frameworks",
                ]),
            ]
        ),
        .executableTarget(
            name: "KeyiSmokeTest",
            dependencies: [
                "KeyiIMEKit",
                "KeyiIMEBridge",
                "KeyiIMEInputController",
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("InputMethodKit"),
                .unsafeFlags([
                    "-L", librimeLib,
                    "-lrime",
                    "-Xlinker", "-rpath",
                    "-Xlinker", "@loader_path/../Frameworks",
                ]),
            ]
        ),
        .executableTarget(
            name: "KeyiNativeProbe",
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Carbon"),
            ]
        ),
        // 自动翻译检查：用替身客户端驱动生产自动翻译控制器。不发真实请求、
        // 不注册输入源、不写用户词库。
        .executableTarget(
            name: "KeyiAutomaticTranslationChecks",
            dependencies: ["KeyiIMETranslation", translationClient],
            path: "Sources/KeyiAutomaticTranslationChecks",
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ]
        ),
    ]
)
