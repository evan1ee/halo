// swift-tools-version: 6.2
import PackageDescription

// HaloMatrixAdapter: the only importer of MatrixRustSDK (docs/architecture/MODULE_BOUNDARIES.md).
// SDK pinned by exact version; checksum is verified by SwiftPM through the package's binary target.
let package = Package(
    name: "HaloMatrixAdapter",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [.library(name: "HaloMatrixAdapter", targets: ["HaloMatrixAdapter"])],
    dependencies: [
        .package(path: "../HaloFoundation"),
        .package(path: "../HaloDomain"),
        .package(path: "../HaloTestSupport"),
        // Test-only: the V-SQL-1 coexistence check and real-server S01–S29 scenarios run Halo's database and coordinators next to the SDK.
        .package(path: "../HaloPersistence"),
        .package(path: "../HaloApplication"),
        .package(url: "https://github.com/element-hq/matrix-rust-components-swift", exact: "26.11.17"),
    ],
    targets: [
        .target(
            name: "HaloMatrixAdapter",
            dependencies: [
                "HaloDomain", "HaloFoundation",
                .product(name: "MatrixRustSDK", package: "matrix-rust-components-swift"),
            ]
        ),
        .testTarget(
            name: "HaloMatrixAdapterTests",
            dependencies: ["HaloMatrixAdapter", "HaloTestSupport", "HaloPersistence", "HaloApplication"]
        ),
    ]
)
