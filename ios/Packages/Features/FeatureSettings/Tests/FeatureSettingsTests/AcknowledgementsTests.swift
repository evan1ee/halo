import Foundation
import Testing
@testable import FeatureSettings

@Suite("Acknowledgements")
struct AcknowledgementsTests {
    @Test("the CSV is parsed, quoted fields and short lines included")
    func parsing() {
        let list = Acknowledgements.parse("crate,version,license,repository,x\na,1.0,MIT,https://a,no\n\"b\",2,\"MIT, Apache-2.0\",\nbad\n")
        #expect(list.map(\.name) == ["a", "b"] && list[1].license == "MIT, Apache-2.0" && list[0].repository == "https://a")
    }

    @Test("search matches the name or the licence, ignoring case")
    func searching() {
        let list = Acknowledgements.parse("c,v,l\nserde,1,MIT OR Apache-2.0\nring,2,ISC\n")
        #expect(Acknowledgements.filter(list, query: "SER").map(\.name) == ["serde"])
        #expect(Acknowledgements.filter(list, query: "isc").map(\.name) == ["ring"])
        #expect(Acknowledgements.filter(list, query: "  ").count == 2)
    }

    @Test("AC-SET-1: the bundled list is exactly the committed licence inventory")
    func matchesInventory() throws {
        let inventory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()  // FeatureSettings/
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()  // repository root
            .appendingPathComponent("docs/security/inventory/rust-deps-matrix-sdk-ffi.csv")
        let committed = try String(contentsOf: inventory, encoding: .utf8)
        #expect(Acknowledgements.parse(committed) == Acknowledgements.bundled())
        #expect(Acknowledgements.bundled().count > 100)
    }

    @Test("AC-SET-1: direct Swift package acknowledgements match the pinned SDK and GRDB versions")
    func matchesSwiftPackages() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let sdkVersionFile = try String(contentsOf: root.appendingPathComponent("ios/SDKVERSION.md"), encoding: .utf8)
        let grdbPackage = try String(contentsOf: root.appendingPathComponent("ios/Packages/HaloPersistence/Package.swift"), encoding: .utf8)

        let sdk = try #require(Acknowledgements.swiftPackages.first { $0.name == "matrix-rust-components-swift" })
        #expect(sdkVersionFile.contains("package_version: \(sdk.version)"))
        #expect(sdk.license == "Apache-2.0")

        let grdb = try #require(Acknowledgements.swiftPackages.first { $0.name == "GRDB.swift" })
        #expect(grdbPackage.contains("exact: \"\(grdb.version)\""))
        #expect(grdb.license == "MIT")

        #expect(Acknowledgements.all().count == Acknowledgements.swiftPackages.count + Acknowledgements.bundled().count)
    }
}
