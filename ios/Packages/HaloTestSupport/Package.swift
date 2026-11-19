// swift-tools-version: 6.2
import PackageDescription

// HaloTestSupport: in-memory fakes of every port and the shared port contract suites
// (docs/matrix/PORTS_CONTRACT.md §1 rule 5, docs/testing/INTEGRATION_TESTS.md §3). Depends only on
// HaloDomain and HaloFoundation, so any package's tests can use it without a dependency cycle.
let package = Package(
    name: "HaloTestSupport",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [.library(name: "HaloTestSupport", targets: ["HaloTestSupport"])],
    dependencies: [.package(path: "../HaloFoundation"), .package(path: "../HaloDomain")],
    targets: [
        .target(name: "HaloTestSupport", dependencies: ["HaloDomain", "HaloFoundation"]),
        .testTarget(name: "HaloTestSupportTests", dependencies: ["HaloTestSupport"]),
    ]
)
