// swift-tools-version: 6.2
import PackageDescription

// FeatureAuth: sign-in screens and view model. Depends on HaloApplication/HaloDomain only
// (docs/architecture/MODULE_BOUNDARIES.md); never on another feature or on infrastructure.
let package = Package(
    name: "FeatureAuth",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [.library(name: "FeatureAuth", targets: ["FeatureAuth"])],
    dependencies: [
        .package(path: "../../HaloFoundation"),
        .package(path: "../../HaloDomain"),
        .package(path: "../../HaloApplication"),
        .package(path: "../../HaloDesignSystem"),
        .package(path: "../../HaloTestSupport"),
    ],
    targets: [
        .target(name: "FeatureAuth", dependencies: ["HaloApplication", "HaloDesignSystem", "HaloDomain", "HaloFoundation"]),
        .testTarget(name: "FeatureAuthTests", dependencies: ["FeatureAuth", "HaloTestSupport"]),
    ]
)
