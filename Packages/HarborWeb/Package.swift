// Licensed under GPL-3.0. See LICENSE.
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HarborWeb",
    platforms: [.macOS("26.0"), .iOS("26.0")],
    products: [
        .library(name: "HarborWeb", targets: ["HarborWeb"]),
    ],
    dependencies: [
        .package(path: "../HarborTabsCore"),
        .package(path: "../HarborSettings"),
        .package(path: "../HarborBlocker"),
        .package(path: "../HarborTweaks"),
        .package(url: "https://github.com/will-lumley/FaviconFinder.git", from: "5.1.5"),
    ],
    targets: [
        .target(name: "MuteableWKWebView", path: "Sources/MuteableWKWebView", publicHeadersPath: "include"),
        .target(
            name: "HarborWeb",
            dependencies: [
                // Page muting reaches a private WebKit call through NSTask and nm; macOS only.
                .target(name: "MuteableWKWebView", condition: .when(platforms: [.macOS])),
                .product(name: "HarborTabsCore", package: "HarborTabsCore"),
                .product(name: "HarborSettings", package: "HarborSettings"),
                .product(name: "HarborBlocker", package: "HarborBlocker"),
                .product(name: "HarborTweaks", package: "HarborTweaks"),
                .product(name: "FaviconFinder", package: "FaviconFinder"),
            ],
            resources: [.copy("Resources")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
