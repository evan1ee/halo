// swift-tools-version: 6.2
import PackageDescription

// FeatureTimeline: the room timeline (M1: read-only). Depends on HaloApplication/HaloDomain only
// (docs/architecture/MODULE_BOUNDARIES.md); never on another feature or on infrastructure.
let package = Package(
    name: "FeatureTimeline",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [.library(name: "FeatureTimeline", targets: ["FeatureTimeline"])],
    dependencies: [
        .package(path: "../../HaloFoundation"),
        .package(path: "../../HaloDomain"),
        .package(path: "../../HaloApplication"),
        .package(path: "../../HaloDesignSystem"),
        .package(path: "../../HaloBotRendering"),
        .package(path: "../../HaloTestSupport"),
    ],
    targets: [
        .target(name: "FeatureTimeline", dependencies: ["HaloApplication", "HaloBotRendering", "HaloDesignSystem", "HaloDomain", "HaloFoundation"]),
        .testTarget(name: "FeatureTimelineTests", dependencies: ["FeatureTimeline", "HaloTestSupport"]),
    ]
)
