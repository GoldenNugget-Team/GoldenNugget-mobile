// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MinimuxerGateway",
    platforms: [
        .iOS(.v14),
        .macOS(.v11),
        .tvOS(.v14)
    ],
    products: [
        .library(
            name: "DeviceGatewayAPI",
            targets: ["DeviceGatewayAPI"]
        ),
        .library(
            name: "IdeviceGateway",
            targets: ["IdeviceGateway"]
        ),
        .library(
            name: "IdeviceGateway-Dynamic",
            type: .dynamic,
            targets: ["IdeviceGateway"]
        )
    ],
    dependencies: [
        .package(path: "../MinimuxerCommon")
    ],
    targets: [
        .binaryTarget(
            name: "IDevice",
            path: "../IDevice.xcframework"
        ),

        // Base API Target
        .target(
            name: "DeviceGatewayAPI",
            dependencies: [
                .product(name: "MinimuxerCommon", package: "MinimuxerCommon")
            ],
            path: ".",
            exclude: [
                "idevice",
                "libimobiledevice"
            ],
            sources: [
                "BaseDeviceGateway.swift",
                "DeviceGatewayAPI.swift",
                "DeviceGatewayError.swift",
                "DeviceGatewayLogging.swift"
            ]
        ),

        // Dynamic Idevice Target
        .target(
            name: "IdeviceGateway",
            dependencies: [
                "DeviceGatewayAPI",
                .product(name: "MinimuxerCommon", package: "MinimuxerCommon"),
                "IDevice"
            ],
            path: "idevice"
        )
    ],
    cxxLanguageStandard: .cxx17
)