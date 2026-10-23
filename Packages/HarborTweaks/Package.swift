// Licensed under GPL-3.0. See LICENSE.
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HarborTweaks",
    platforms: [.macOS("26.0"), .iOS("26.0")],
    products: [
        .library(name: "HarborTweaks", targets: ["HarborTweaks"]),
    ],
    dependencies: [
        .package(path: "../HarborSettings"),
        .package(path: "../HarborBlocker"),
    ],
    targets: [
        .target(
            name: "HarborTweaks",
            dependencies: [
                .product(name: "HarborSettings", package: "HarborSettings"),
                .product(name: "HarborBlocker", package: "HarborBlocker"),
            ],
            resources: [.copy("Resources")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
