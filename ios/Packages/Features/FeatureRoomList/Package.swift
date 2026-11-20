// swift-tools-version: 6.2
import PackageDescription

// FeatureRoomList: the room list screen and view model (M0: room count). Depends on HaloApplication/HaloDomain only
// (docs/architecture/MODULE_BOUNDARIES.md); never on another feature or on infrastructure.
let package = Package(
    name: "FeatureRoomList",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [.library(name: "FeatureRoomList", targets: ["FeatureRoomList"])],
    dependencies: [
        .package(path: "../../HaloFoundation"),
        .package(path: "../../HaloDomain"),
        .package(path: "../../HaloDesignSystem"),
        .package(path: "../../HaloApplication"),
        .package(path: "../../HaloTestSupport"),
    ],
    targets: [
        .target(name: "FeatureRoomList", dependencies: ["HaloApplication", "HaloDesignSystem", "HaloDomain", "HaloFoundation"]),
        .testTarget(name: "FeatureRoomListTests", dependencies: ["FeatureRoomList", "HaloTestSupport"]),
    ]
)
