// Licensed under GPL-3.0. See LICENSE.
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HarborBlocker",
    platforms: [.macOS("26.0"), .iOS("26.0")],
    products: [
        .library(name: "HarborBlocker", targets: ["HarborBlocker"]),
    ],
    dependencies: [
        .package(path: "../HarborSettings"),
    ],
    targets: [
        .binaryTarget(
            name: "HarborAdblockFFI",
            path: "../../Harbor/ThirdParty/AdblockRustFFI/HarborAdblock.xcframework"
        ),
        .target(
            name: "HarborBlocker",
            dependencies: [
                "HarborAdblockFFI",
                .product(name: "HarborSettings", package: "HarborSettings"),
            ],
            resources: [.copy("Resources")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
