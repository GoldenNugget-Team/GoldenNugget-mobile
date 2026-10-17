// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "AssetKit",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .library(
            name: "AssetKit",
            targets: ["AssetKit"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/tayloraswift/swift-png", from: "4.5.0"),
    ],
    targets: [
        .target(
            name: "CLZFSE",
            path: "Sources/CLZFSE",
            exclude: ["LICENSE", "UPSTREAM.md"],
            publicHeadersPath: "include"
        ),
        .target(
            name: "AssetKit",
            dependencies: [
                .product(name: "PNG", package: "swift-png"),
                "CLZFSE",
            ]
        ),
        .testTarget(
            name: "AssetKitTests",
            dependencies: [
                "AssetKit",
                "CLZFSE",
            ],
            resources: [
                .copy("Fixtures"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
