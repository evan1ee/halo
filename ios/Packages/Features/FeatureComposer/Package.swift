// swift-tools-version: 6.2
import PackageDescription

// FeatureComposer: timeline message composer, attachments, mentions, and emoji autocomplete (ADR-0022 step 3).
// Depends on HaloApplication, HaloDesignSystem, HaloDomain, HaloFoundation only.
let package = Package(
    name: "FeatureComposer",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [.library(name: "FeatureComposer", targets: ["FeatureComposer"])],
    dependencies: [
        .package(path: "../../HaloFoundation"),
        .package(path: "../../HaloDomain"),
        .package(path: "../../HaloApplication"),
        .package(path: "../../HaloDesignSystem"),
        .package(path: "../../HaloTestSupport"),
    ],
    targets: [
        .target(name: "FeatureComposer", dependencies: ["HaloApplication", "HaloDesignSystem", "HaloDomain", "HaloFoundation"]),
        .testTarget(name: "FeatureComposerTests", dependencies: ["FeatureComposer", "HaloTestSupport"]),
    ]
)
