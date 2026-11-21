// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CZCommander",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "CZCommanderCore",
            targets: ["CZCommanderCore"]
        ),
        .executable(
            name: "CZCommander",
            targets: ["CZCommander"]
        )
    ],
    targets: [
        .target(
            name: "CZCommanderCore",
            path: "Sources/CZCommanderCore",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        .target(
            name: "BRAWBridge",
            path: "Sources/BRAWBridge",
            exclude: ["BlackmagicSDK/README.md"],
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedFramework("CoreFoundation"),
                .linkedFramework("CoreGraphics")
            ]
        ),
        .executableTarget(
            name: "CZCommander",
            dependencies: ["CZCommanderCore", "BRAWBridge"],
            path: "Sources/CZCommanderApp",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        .testTarget(
            name: "CZCommanderTests",
            dependencies: ["CZCommanderCore"],
            path: "Tests/CZCommanderTests",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        )
    ],
    cxxLanguageStandard: .cxx17
)
