// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Minimuxer",
    platforms: [
        .iOS(.v14),
        .macOS(.v11),
        .tvOS(.v14)
    ],
    products: [
        .library(
            name: "Minimuxer",
            targets: ["Minimuxer"]
        ),
        // Exposed as a product, not only as Minimuxer's dependency, because the
        // app unpacks `.tendies` wallpaper packs itself (ZIPFoundation already
        // ships in this package — its upstream manifest evaluates
        // `canImport(Compression)` on the build host, which would pull the
        // pkg-config CZLib path instead of Apple's Compression framework).
        .library(
            name: "ZIPFoundation",
            targets: ["ZIPFoundation"]
        ),
        // The AirTraffic sandbox escape (AirLift), as a C FFI the app calls
        // directly.  A product rather than a Minimuxer dependency on purpose:
        // Minimuxer has its own idea of the device connection, and the exploit
        // is given a *pairing file path* and opens its own tunnel — folding it
        // into Minimuxer would make the two connections contend for the same
        // lockdownd session.  MIT; see Vendor/AirliftFFI.xcframework/README.md.
        .library(
            name: "AirliftFFI",
            targets: ["AirliftFFI"]
        )
    ],
    dependencies: [
        .package(path: "MinimuxerCommon"),
        .package(path: "MinimuxerGateway")
    ],
    targets: [
        // Dynamic framework wrapping of em_proxy. Its Rust std copy of
        // `rust_eh_personality` would collide with libidevice_ffi's at final
        // link if both were static, so em_proxy ships as a dylib.
        .binaryTarget(
            name: "EMProxy",
            path: "EMProxy-dynamic.xcframework"
        ),

        // Local vendored copy of ZIPFoundation (its upstream manifest evaluates
        // `canImport(Compression)` on the build host, which would pull the
        // pkg-config CZLib/zlib path instead of Apple's Compression framework).
        .target(
            name: "ZIPFoundation",
            path: "ZIPFoundation",
            exclude: ["Sources/Resources"]
        ),

        // AirLift's AirTraffic sandbox escape as a C FFI, prebuilt by
        // AirCard-iOS (MIT) against the iOS 27 SDK.  The simulator slice is
        // dropped: this package ships a sideloaded .ipa and nothing links it
        // for the simulator, so keeping it would double the vendored size for
        // a library that can never be reached.
        .binaryTarget(
            name: "AirliftFFI",
            path: "AirliftFFI.xcframework"
        ),

        // Main SPM target
        .target(
            name: "Minimuxer",
            dependencies: [
                .product(name: "MinimuxerCommon", package: "MinimuxerCommon"),
                .product(name: "DeviceGatewayAPI", package: "MinimuxerGateway"),
                .product(name: "IdeviceGateway", package: "MinimuxerGateway"),
                "EMProxy",
                "ZIPFoundation"
            ],
            path: "MinimuxerSources"
        )
    ],
    cLanguageStandard: .gnu11,
    cxxLanguageStandard: .gnucxx14
)