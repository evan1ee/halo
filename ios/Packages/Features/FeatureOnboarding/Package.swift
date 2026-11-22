// swift-tools-version: 6.2
import PackageDescription

// FeatureOnboarding: welcome, sign-in, device verification, notification priming, and first-run checklist (ADR-0022 step 3).
// Depends on HaloApplication, HaloDesignSystem, HaloDomain, HaloFoundation only.
let package = Package(
    name: "FeatureOnboarding",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [.library(name: "FeatureOnboarding", targets: ["FeatureOnboarding"])],
    dependencies: [
        .package(path: "../../HaloFoundation"),
        .package(path: "../../HaloDomain"),
        .package(path: "../../HaloApplication"),
        .package(path: "../../HaloDesignSystem"),
        .package(path: "../../HaloTestSupport"),
    ],
    targets: [
        .target(name: "FeatureOnboarding", dependencies: ["HaloApplication", "HaloDesignSystem", "HaloDomain", "HaloFoundation"]),
        .testTarget(name: "FeatureOnboardingTests", dependencies: ["FeatureOnboarding", "HaloTestSupport"]),
    ]
)
