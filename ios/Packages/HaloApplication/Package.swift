// swift-tools-version: 6.2
import PackageDescription

// HaloApplication: coordinators and use cases. No SwiftUI/UIKit/UserNotifications; must build on
// Linux (docs/architecture/MODULE_BOUNDARIES.md).
let package = Package(
    name: "HaloApplication",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [.library(name: "HaloApplication", targets: ["HaloApplication"])],
    dependencies: [
        .package(path: "../HaloFoundation"),
        .package(path: "../HaloDomain"),
        .package(path: "../HaloTestSupport"),
    ],
    targets: [
        .target(name: "HaloApplication", dependencies: ["HaloDomain", "HaloFoundation"]),
        .testTarget(name: "HaloApplicationTests", dependencies: ["HaloApplication", "HaloTestSupport"]),
    ]
)
