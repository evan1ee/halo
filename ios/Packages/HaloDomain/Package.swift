// swift-tools-version: 6.2
import PackageDescription

// HaloDomain: value models, ports (protocols) and pure policies. Imports only HaloFoundation;
// must build on Linux (docs/architecture/MODULE_BOUNDARIES.md).
let package = Package(
    name: "HaloDomain",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [.library(name: "HaloDomain", targets: ["HaloDomain"])],
    dependencies: [.package(path: "../HaloFoundation")],
    targets: [
        .target(name: "HaloDomain", dependencies: ["HaloFoundation"]),
        .testTarget(name: "HaloDomainTests", dependencies: ["HaloDomain", "HaloFoundation"]),
    ]
)
