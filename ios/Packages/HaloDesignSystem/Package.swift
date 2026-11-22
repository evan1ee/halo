// swift-tools-version: 6.2
import PackageDescription

// HaloDesignSystem: shared SwiftUI building blocks without business logic (docs/architecture/MODULE_BOUNDARIES.md).
// Imports HaloFoundation only; features depend on it, never the other way round.
let package = Package(
    name: "HaloDesignSystem",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [.library(name: "HaloDesignSystem", targets: ["HaloDesignSystem"])],
    targets: [
        .target(
            name: "HaloDesignSystem",
            resources: [.process("Resources")]
        ),
        .testTarget(name: "HaloDesignSystemTests", dependencies: ["HaloDesignSystem"]),
    ]
)
