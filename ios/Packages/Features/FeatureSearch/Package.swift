// swift-tools-version: 6.2
import PackageDescription

// FeatureSearch: message search results and view model (ADR-0022 step 2, M12).
// Depends on HaloApplication, HaloDesignSystem, HaloDomain, HaloFoundation only.
let package = Package(
    name: "FeatureSearch",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [.library(name: "FeatureSearch", targets: ["FeatureSearch"])],
    dependencies: [
        .package(path: "../../HaloFoundation"),
        .package(path: "../../HaloDomain"),
        .package(path: "../../HaloApplication"),
        .package(path: "../../HaloDesignSystem"),
        .package(path: "../../HaloTestSupport"),
    ],
    targets: [
        .target(name: "FeatureSearch", dependencies: ["HaloApplication", "HaloDesignSystem", "HaloDomain", "HaloFoundation"]),
        .testTarget(name: "FeatureSearchTests", dependencies: ["FeatureSearch", "HaloTestSupport"]),
    ]
)
