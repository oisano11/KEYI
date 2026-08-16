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
        .executableTarget(
            name: "KEYI",
            dependencies: ["KEYICore"],
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
        )
    ]
)
