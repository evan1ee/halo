// swift-tools-version: 6.2
import PackageDescription

// FeatureBotActivity: the Activity screen (docs/features/BOT_ACTIVITY.md): open tasks, reminders and recently completed tasks that
// known bots told the user about, from the derived index. Depends on HaloApplication/HaloDomain/HaloDesignSystem only; never on another feature.
let package = Package(
    name: "FeatureBotActivity",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [.library(name: "FeatureBotActivity", targets: ["FeatureBotActivity"])],
    dependencies: [
        .package(path: "../../HaloFoundation"),
        .package(path: "../../HaloDomain"),
        .package(path: "../../HaloDesignSystem"),
        .package(path: "../../HaloApplication"),
        .package(path: "../../HaloTestSupport"),
    ],
    targets: [
        .target(name: "FeatureBotActivity", dependencies: ["HaloApplication", "HaloDesignSystem", "HaloDomain", "HaloFoundation"]),
        .testTarget(name: "FeatureBotActivityTests", dependencies: ["FeatureBotActivity", "HaloTestSupport"]),
    ]
)
