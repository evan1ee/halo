// swift-tools-version: 6.2
import PackageDescription

// FeatureStickers: the sticker panel (docs/features/STICKERS.md). Depends on HaloApplication/HaloDomain only
// (docs/architecture/MODULE_BOUNDARIES.md); never on another feature or on infrastructure.
let package = Package(
    name: "FeatureStickers",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [.library(name: "FeatureStickers", targets: ["FeatureStickers"])],
    dependencies: [
        .package(path: "../../HaloFoundation"),
        .package(path: "../../HaloDomain"),
        .package(path: "../../HaloApplication"),
        .package(path: "../../HaloTestSupport"),
    ],
    targets: [
        .target(name: "FeatureStickers", dependencies: ["HaloApplication", "HaloDomain", "HaloFoundation"]),
        .testTarget(name: "FeatureStickersTests", dependencies: ["FeatureStickers", "HaloTestSupport"]),
    ]
)
