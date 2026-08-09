// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "ExitWatch",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "ExitWatchCore",
            targets: ["ExitWatchCore"]
        ),
        .executable(
            name: "ExitWatch",
            targets: ["ExitWatch"]
        )
    ],
    targets: [
        .target(
            name: "ExitWatchCore"
        ),
        .executableTarget(
            name: "ExitWatch",
            dependencies: ["ExitWatchCore"]
        ),
        .testTarget(
            name: "ExitWatchCoreTests",
            dependencies: ["ExitWatchCore"]
        )
    ],
    swiftLanguageVersions: [.v5]
)
