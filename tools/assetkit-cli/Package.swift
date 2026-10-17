// swift-tools-version: 6.2
import PackageDescription

// An actool-shaped CLI backed by xtool-org/AssetKit, which is a clean-room
// reimplementation of Apple's actool.  Apple's own actool is a macOS-only
// Mach-O binary (the copy inside the darwin SDK artifactbundle is
// "Mach-O 64-bit arm64"), so it cannot run on this x86_64 Linux host — xtool
// copies it into xtool/.xtool-tmp/actool and then dies with
// "is not an executable file" / "Exec format error".
//
// This executable speaks the slice of actool's CLI that xtool would use, and
// scripts/compile-assets.sh drives it to turn Assets.xcassets into Assets.car
// plus the loose icon PNGs on Linux.  It is not installed into xtool's
// .xtool-tmp/actool: that path is rewritten on every build, and the copy xtool
// makes never gets the executable bit, so there is nothing to install into.
//
// AssetKit itself is vendored at tools/AssetKit and patched locally, because
// upstream 1.0.0 cannot express a dark app-icon appearance (see the
// "Local patch" comments in Sources/AssetKit).  To move to an upstream release
// with real app-icon support, drop the `path:` dependency and re-test
// --dump-renditions output.
let package = Package(
    name: "assetkit-cli",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(path: "../AssetKit"),
    ],
    targets: [
        .executableTarget(
            name: "assetkit-cli",
            dependencies: [.product(name: "AssetKit", package: "AssetKit")]
        )
    ],
    swiftLanguageModes: [.v6]
)
