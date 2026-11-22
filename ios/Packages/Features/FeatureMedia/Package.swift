// swift-tools-version: 6.2
import PackageDescription

// FeatureMedia: Global Media Gallery and shared media presentation (ADR-0022 step 3, M9/M13).
// Depends on HaloApplication, HaloDesignSystem, HaloDomain, HaloFoundation only.
let package = Package(
    name: "FeatureMedia",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [.library(name: "FeatureMedia", targets: ["FeatureMedia"])],
    dependencies: [
        .package(path: "../../HaloFoundation"),
        .package(path: "../../HaloDomain"),
        .package(path: "../../HaloApplication"),
        .package(path: "../../HaloDesignSystem"),
        .package(path: "../../HaloTestSupport"),
    ],
    targets: [
        .target(name: "FeatureMedia", dependencies: ["HaloApplication", "HaloDesignSystem", "HaloDomain", "HaloFoundation"]),
        .testTarget(name: "FeatureMediaTests", dependencies: ["FeatureMedia", "HaloTestSupport"]),
    ]
)
