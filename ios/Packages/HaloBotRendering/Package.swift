// swift-tools-version: 6.2
import PackageDescription

// HaloBotRendering: native bot cards and Matrix HTML subset renderer (ADR-0022 step 3, MODULE_BOUNDARIES §1).
// Depends on HaloDomain and HaloDesignSystem only.
let package = Package(
    name: "HaloBotRendering",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [.library(name: "HaloBotRendering", targets: ["HaloBotRendering"])],
    dependencies: [
        .package(path: "../HaloFoundation"),
        .package(path: "../HaloDomain"),
        .package(path: "../HaloDesignSystem"),
    ],
    targets: [
        .target(name: "HaloBotRendering", dependencies: ["HaloDomain", "HaloDesignSystem", "HaloFoundation"]),
        .testTarget(name: "HaloBotRenderingTests", dependencies: ["HaloBotRendering"]),
    ]
)
