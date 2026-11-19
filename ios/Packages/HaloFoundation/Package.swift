// swift-tools-version: 6.2
import PackageDescription

// HaloFoundation: cross-cutting base used by every Halo module; imports nothing from Halo
// (docs/architecture/MODULE_BOUNDARIES.md). Must build on Linux.
let package = Package(
    name: "HaloFoundation",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [.library(name: "HaloFoundation", targets: ["HaloFoundation"])],
    targets: [
        .target(name: "HaloFoundation"),
        .testTarget(name: "HaloFoundationTests", dependencies: ["HaloFoundation"]),
    ]
)
