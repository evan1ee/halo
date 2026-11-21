// swift-tools-version: 6.2
import PackageDescription

// FeatureSettings: settings, about and acknowledgements screens (docs/features/SETTINGS.md). Depends on
// HaloFoundation only; actions (sign out) come in as closures from the composition root.
let package = Package(
    name: "FeatureSettings",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [.library(name: "FeatureSettings", targets: ["FeatureSettings"])],
    dependencies: [.package(path: "../../HaloFoundation"), .package(path: "../../HaloDesignSystem")],
    targets: [
        .target(name: "FeatureSettings", dependencies: ["HaloFoundation", "HaloDesignSystem"], resources: [.copy("Resources/acknowledgements.csv")]),
        .testTarget(name: "FeatureSettingsTests", dependencies: ["FeatureSettings"]),
    ]
)
