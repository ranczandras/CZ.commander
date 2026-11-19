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
        .executableTarget(
            name: "CZCommander",
            dependencies: ["CZCommanderCore"],
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
    ]
)
