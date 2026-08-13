// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "HanYi",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(name: "HanYi", targets: ["HanYi"])
    ],
    targets: [
        .target(name: "HanYiCore"),
        .executableTarget(
            name: "HanYi",
            dependencies: ["HanYiCore"],
            linkerSettings: [
                .linkedFramework("ApplicationServices"),
                .linkedFramework("Carbon"),
                .linkedFramework("Translation")
            ]
        ),
        .executableTarget(
            name: "HanYiCoreChecks",
            dependencies: ["HanYiCore"],
            path: "Tests/HanYiCoreChecks"
        )
    ]
)
