// Licensed under GPL-3.0. See LICENSE.
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HarborUI",
    platforms: [.macOS("26.0"), .iOS("26.0")],
    products: [
        .library(name: "HarborUI", targets: ["HarborUI"]),
    ],
    dependencies: [
        .package(path: "../HarborBlocker"),
        .package(path: "../HarborDesign"),
        .package(path: "../HarborSettings"),
        .package(path: "../HarborTabsCore"),
        .package(path: "../HarborTweaks"),
        .package(path: "../HarborWeb"),
    ],
    targets: [
        .target(
            name: "HarborUI",
            dependencies: [
                .product(name: "HarborBlocker", package: "HarborBlocker"),
                .product(name: "HarborDesign", package: "HarborDesign"),
                .product(name: "HarborSettings", package: "HarborSettings"),
                .product(name: "HarborTabsCore", package: "HarborTabsCore"),
                .product(name: "HarborTweaks", package: "HarborTweaks"),
                .product(name: "HarborWeb", package: "HarborWeb"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
