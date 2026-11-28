// swift-tools-version: 6.2
import PackageDescription

// HaloApple: Apple-platform layers and feature modules of Halo (ADR-0022 step 4, D86).
// Boundaries remain compiler-enforced via target dependencies: only HaloMatrixAdapter depends on
// MatrixRustSDK, and no Feature* target depends on infrastructure or another Feature*.
let package = Package(
    name: "HaloApple",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "HaloPersistence", targets: ["HaloPersistence"]),
        .library(name: "HaloPlatform", targets: ["HaloPlatform"]),
        .library(name: "HaloMatrixAdapter", targets: ["HaloMatrixAdapter"]),
        .library(name: "HaloDesignSystem", targets: ["HaloDesignSystem"]),
        .library(name: "HaloBotRendering", targets: ["HaloBotRendering"]),
        .library(name: "FeatureOnboarding", targets: ["FeatureOnboarding"]),
        .library(name: "FeatureRoomList", targets: ["FeatureRoomList"]),
        .library(name: "FeatureTimeline", targets: ["FeatureTimeline"]),
        .library(name: "FeatureMedia", targets: ["FeatureMedia"]),
        .library(name: "FeatureRoomDetails", targets: ["FeatureRoomDetails"]),
        .library(name: "FeatureProfile", targets: ["FeatureProfile"]),
        .library(name: "FeatureSearch", targets: ["FeatureSearch"]),
        .library(name: "FeatureStickers", targets: ["FeatureStickers"]),
        .library(name: "FeatureBotActivity", targets: ["FeatureBotActivity"]),
        .library(name: "FeatureSettings", targets: ["FeatureSettings"]),
    ],
    dependencies: [
        .package(path: "../HaloCore"),
        .package(url: "https://github.com/groue/GRDB.swift", exact: "7.12.0"),
        .package(url: "https://github.com/element-hq/matrix-rust-components-swift", exact: "26.11.17"),
    ],
    targets: [
        // Infrastructure layers
        .target(
            name: "HaloPersistence",
            dependencies: [
                .product(name: "HaloDomain", package: "HaloCore"),
                .product(name: "HaloFoundation", package: "HaloCore"),
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        .testTarget(
            name: "HaloPersistenceTests",
            dependencies: [
                "HaloPersistence",
                .product(name: "HaloDomain", package: "HaloCore"),
                .product(name: "HaloFoundation", package: "HaloCore"),
            ]
        ),

        .target(
            name: "HaloPlatform",
            dependencies: [
                .product(name: "HaloDomain", package: "HaloCore"),
                .product(name: "HaloFoundation", package: "HaloCore"),
            ]
        ),
        .testTarget(
            name: "HaloPlatformTests",
            dependencies: [
                "HaloPlatform",
                .product(name: "HaloDomain", package: "HaloCore"),
                .product(name: "HaloFoundation", package: "HaloCore"),
                .product(name: "HaloTestSupport", package: "HaloCore"),
            ]
        ),

        .target(
            name: "HaloMatrixAdapter",
            dependencies: [
                .product(name: "HaloDomain", package: "HaloCore"),
                .product(name: "HaloFoundation", package: "HaloCore"),
                .product(name: "MatrixRustSDK", package: "matrix-rust-components-swift"),
            ]
        ),
        .testTarget(
            name: "HaloMatrixAdapterTests",
            dependencies: [
                "HaloMatrixAdapter",
                "HaloPersistence",
                .product(name: "HaloApplication", package: "HaloCore"),
                .product(name: "HaloTestSupport", package: "HaloCore"),
                .product(name: "HaloDomain", package: "HaloCore"),
                .product(name: "HaloFoundation", package: "HaloCore"),
            ]
        ),

        // Presentation shared layers
        .target(
            name: "HaloDesignSystem",
            dependencies: [.product(name: "HaloFoundation", package: "HaloCore")],
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "HaloDesignSystemTests",
            dependencies: ["HaloDesignSystem", .product(name: "HaloFoundation", package: "HaloCore")]
        ),

        .target(
            name: "HaloBotRendering",
            dependencies: [
                "HaloDesignSystem",
                .product(name: "HaloDomain", package: "HaloCore"),
                .product(name: "HaloFoundation", package: "HaloCore"),
            ]
        ),
        .testTarget(name: "HaloBotRenderingTests", dependencies: ["HaloBotRendering"]),

        // Features
        .target(
            name: "FeatureOnboarding",
            dependencies: [
                "HaloDesignSystem",
                .product(name: "HaloApplication", package: "HaloCore"),
                .product(name: "HaloDomain", package: "HaloCore"),
                .product(name: "HaloFoundation", package: "HaloCore"),
            ]
        ),
        .testTarget(
            name: "FeatureOnboardingTests",
            dependencies: [
                "FeatureOnboarding",
                .product(name: "HaloTestSupport", package: "HaloCore"),
            ]
        ),

        .target(
            name: "FeatureRoomList",
            dependencies: [
                "HaloDesignSystem",
                .product(name: "HaloApplication", package: "HaloCore"),
                .product(name: "HaloDomain", package: "HaloCore"),
                .product(name: "HaloFoundation", package: "HaloCore"),
            ]
        ),
        .testTarget(
            name: "FeatureRoomListTests",
            dependencies: [
                "FeatureRoomList",
                .product(name: "HaloTestSupport", package: "HaloCore"),
            ]
        ),

        .target(
            name: "FeatureTimeline",
            dependencies: [
                "HaloBotRendering",
                "HaloDesignSystem",
                .product(name: "HaloApplication", package: "HaloCore"),
                .product(name: "HaloDomain", package: "HaloCore"),
                .product(name: "HaloFoundation", package: "HaloCore"),
            ]
        ),
        .testTarget(
            name: "FeatureTimelineTests",
            dependencies: [
                "FeatureTimeline",
                .product(name: "HaloTestSupport", package: "HaloCore"),
            ]
        ),

        .target(
            name: "FeatureMedia",
            dependencies: [
                "HaloDesignSystem",
                .product(name: "HaloApplication", package: "HaloCore"),
                .product(name: "HaloDomain", package: "HaloCore"),
                .product(name: "HaloFoundation", package: "HaloCore"),
            ]
        ),
        .testTarget(
            name: "FeatureMediaTests",
            dependencies: [
                "FeatureMedia",
                .product(name: "HaloTestSupport", package: "HaloCore"),
            ]
        ),

        .target(
            name: "FeatureRoomDetails",
            dependencies: [
                "HaloDesignSystem",
                .product(name: "HaloApplication", package: "HaloCore"),
                .product(name: "HaloDomain", package: "HaloCore"),
                .product(name: "HaloFoundation", package: "HaloCore"),
            ]
        ),
        .testTarget(
            name: "FeatureRoomDetailsTests",
            dependencies: [
                "FeatureRoomDetails",
                .product(name: "HaloTestSupport", package: "HaloCore"),
            ]
        ),

        .target(
            name: "FeatureProfile",
            dependencies: [
                "HaloDesignSystem",
                .product(name: "HaloApplication", package: "HaloCore"),
                .product(name: "HaloDomain", package: "HaloCore"),
                .product(name: "HaloFoundation", package: "HaloCore"),
            ]
        ),
        .testTarget(
            name: "FeatureProfileTests",
            dependencies: [
                "FeatureProfile",
                .product(name: "HaloTestSupport", package: "HaloCore"),
            ]
        ),

        .target(
            name: "FeatureSearch",
            dependencies: [
                "HaloDesignSystem",
                .product(name: "HaloApplication", package: "HaloCore"),
                .product(name: "HaloDomain", package: "HaloCore"),
                .product(name: "HaloFoundation", package: "HaloCore"),
            ]
        ),
        .testTarget(
            name: "FeatureSearchTests",
            dependencies: [
                "FeatureSearch",
                .product(name: "HaloTestSupport", package: "HaloCore"),
            ]
        ),

        .target(
            name: "FeatureStickers",
            dependencies: [
                "HaloDesignSystem",
                .product(name: "HaloApplication", package: "HaloCore"),
                .product(name: "HaloDomain", package: "HaloCore"),
                .product(name: "HaloFoundation", package: "HaloCore"),
            ]
        ),
        .testTarget(
            name: "FeatureStickersTests",
            dependencies: [
                "FeatureStickers",
                .product(name: "HaloTestSupport", package: "HaloCore"),
            ]
        ),

        .target(
            name: "FeatureBotActivity",
            dependencies: [
                "HaloDesignSystem",
                .product(name: "HaloApplication", package: "HaloCore"),
                .product(name: "HaloDomain", package: "HaloCore"),
                .product(name: "HaloFoundation", package: "HaloCore"),
            ]
        ),
        .testTarget(
            name: "FeatureBotActivityTests",
            dependencies: [
                "FeatureBotActivity",
                .product(name: "HaloTestSupport", package: "HaloCore"),
            ]
        ),

        .target(
            name: "FeatureSettings",
            dependencies: [
                "HaloDesignSystem",
                .product(name: "HaloApplication", package: "HaloCore"),
                .product(name: "HaloDomain", package: "HaloCore"),
                .product(name: "HaloFoundation", package: "HaloCore"),
            ],
            resources: [.copy("Resources/acknowledgements.csv")]
        ),
        .testTarget(name: "FeatureSettingsTests", dependencies: ["FeatureSettings"]),
    ]
)
