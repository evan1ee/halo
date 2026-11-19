// swift-tools-version: 6.2
import PackageDescription

// HaloPersistence: Halo's own SQLite database (GRDB) behind domain ports (ADR-0006,
// docs/architecture/MODULE_BOUNDARIES.md). Derived, rebuildable data and explicit intents only (AGENTS.md §4.1).
let package = Package(
    name: "HaloPersistence",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [.library(name: "HaloPersistence", targets: ["HaloPersistence"])],
    dependencies: [
        .package(path: "../HaloFoundation"),
        .package(path: "../HaloDomain"),
        .package(url: "https://github.com/groue/GRDB.swift", exact: "7.12.0"),
    ],
    targets: [
        .target(
            name: "HaloPersistence",
            dependencies: ["HaloDomain", "HaloFoundation", .product(name: "GRDB", package: "GRDB.swift")]),
        .testTarget(name: "HaloPersistenceTests", dependencies: ["HaloPersistence"]),
    ]
)
