// swift-tools-version: 6.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "PortBridge",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .executable(name: "PortBridge", targets: ["PortBridge"]),
        .library(name: "PortBridgeCore", targets: ["PortBridgeCore"]),
    ],
    targets: [
        .target(
            name: "PortBridgeCore"
        ),
        .executableTarget(
            name: "PortBridge",
            dependencies: ["PortBridgeCore"]
        ),
        .testTarget(
            name: "PortBridgeTests",
            dependencies: ["PortBridgeCore"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
