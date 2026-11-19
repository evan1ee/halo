// swift-tools-version: 6.2
import PackageDescription

// HaloPlatform: Apple-API implementations of domain ports (docs/architecture/MODULE_BOUNDARIES.md).
// No Matrix SDK, no Application layer.
let package = Package(
    name: "HaloPlatform",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [.library(name: "HaloPlatform", targets: ["HaloPlatform"])],
    dependencies: [
        .package(path: "../HaloFoundation"),
        .package(path: "../HaloDomain"),
        .package(path: "../HaloTestSupport"),
    ],
    targets: [
        .target(name: "HaloPlatform", dependencies: ["HaloDomain", "HaloFoundation"]),
        .testTarget(name: "HaloPlatformTests", dependencies: ["HaloPlatform", "HaloTestSupport"]),
    ]
)
