// Licensed under GPL-3.0. See LICENSE.
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HarborTabsCore",
    platforms: [.macOS("26.0"), .iOS("26.0")],
    products: [
        .library(name: "HarborTabsCore", targets: ["HarborTabsCore"]),
    ],
    targets: [
        .target(name: "HarborTabsCore", swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "HarborTabsCoreTests", dependencies: ["HarborTabsCore"], swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
