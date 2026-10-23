// Licensed under GPL-3.0. See LICENSE.
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HarborDesign",
    platforms: [.macOS("26.0"), .iOS("26.0")],
    products: [
        .library(name: "HarborDesign", targets: ["HarborDesign"]),
    ],
    targets: [
        .target(name: "HarborDesign", swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
