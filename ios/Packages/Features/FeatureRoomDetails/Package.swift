// swift-tools-version: 6.2
import PackageDescription

// FeatureRoomDetails: the room info sheet (docs/features/ROOM_MANAGEMENT.md): details, members, notification mode, leave.
// Depends on HaloDomain/HaloFoundation only; never on another feature.
let package = Package(
    name: "FeatureRoomDetails",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [.library(name: "FeatureRoomDetails", targets: ["FeatureRoomDetails"])],
    dependencies: [
        .package(path: "../../HaloFoundation"),
        .package(path: "../../HaloDomain"),
        .package(path: "../../HaloDesignSystem"),
        .package(path: "../../HaloApplication"),
        .package(path: "../../HaloTestSupport"),
    ],
    targets: [
        .target(name: "FeatureRoomDetails", dependencies: ["HaloApplication", "HaloDesignSystem", "HaloDomain", "HaloFoundation"]),
        .testTarget(name: "FeatureRoomDetailsTests", dependencies: ["FeatureRoomDetails", "HaloTestSupport"]),
    ]
)
