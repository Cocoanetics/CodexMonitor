// swift-tools-version: 6.1
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "CodexMonitor",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(name: "CodexCore", targets: ["CodexCore"]),
        .executable(
            name: "CodexMonitor-CLI",
            targets: ["CodexMonitorCLI"]
        ),
        .executable(
            name: "CodexMonitor-App",
            targets: ["CodexMonitorApp"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
        .package(url: "https://github.com/apple/swift-log", from: "1.5.0")
    ],
    targets: [
        .target(
            name: "CodexCore",
            dependencies: []
        ),
        .executableTarget(
            name: "CodexMonitorCLI",
            dependencies: [
                "CodexCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Logging", package: "swift-log")
            ]
        ),
        .executableTarget(
            name: "CodexMonitorApp",
            dependencies: [
                "CodexCore",
                .product(name: "Logging", package: "swift-log")
            ]
        )
    ]
)
