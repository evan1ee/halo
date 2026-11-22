// swift-tools-version: 6.2
import PackageDescription

// HaloCore: Linux-buildable core layers of Halo (ADR-0022 step 4, D86).
// Module boundaries are compiler-enforced via target dependencies (MODULE_BOUNDARIES.md §1–2).
let package = Package(
    name: "HaloCore",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "HaloFoundation", targets: ["HaloFoundation"]),
        .library(name: "HaloDomain", targets: ["HaloDomain"]),
        .library(name: "HaloApplication", targets: ["HaloApplication"]),
        .library(name: "HaloTestSupport", targets: ["HaloTestSupport"]),
    ],
    targets: [
        .target(name: "HaloFoundation"),
        .testTarget(name: "HaloFoundationTests", dependencies: ["HaloFoundation"]),

        .target(name: "HaloDomain", dependencies: ["HaloFoundation"]),
        .testTarget(name: "HaloDomainTests", dependencies: ["HaloDomain", "HaloFoundation"]),

        .target(name: "HaloTestSupport", dependencies: ["HaloDomain", "HaloFoundation"]),
        .testTarget(name: "HaloTestSupportTests", dependencies: ["HaloTestSupport", "HaloDomain", "HaloFoundation"]),

        .target(name: "HaloApplication", dependencies: ["HaloDomain", "HaloFoundation"]),
        .testTarget(
            name: "HaloApplicationTests",
            dependencies: ["HaloApplication", "HaloTestSupport", "HaloDomain", "HaloFoundation"]
        ),
    ]
)
