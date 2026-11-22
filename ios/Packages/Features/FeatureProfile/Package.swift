// swift-tools-version: 6.2
import PackageDescription

// FeatureProfile: user profiles and own-profile settings (ADR-0022 step 2, M12).
// Depends on HaloApplication, HaloDesignSystem, HaloDomain, HaloFoundation only.
let package = Package(
    name: "FeatureProfile",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [.library(name: "FeatureProfile", targets: ["FeatureProfile"])],
    dependencies: [
        .package(path: "../../HaloFoundation"),
        .package(path: "../../HaloDomain"),
        .package(path: "../../HaloApplication"),
        .package(path: "../../HaloDesignSystem"),
        .package(path: "../../HaloTestSupport"),
    ],
    targets: [
        .target(name: "FeatureProfile", dependencies: ["HaloApplication", "HaloDesignSystem", "HaloDomain", "HaloFoundation"]),
        .testTarget(name: "FeatureProfileTests", dependencies: ["FeatureProfile", "HaloTestSupport"]),
    ]
)
