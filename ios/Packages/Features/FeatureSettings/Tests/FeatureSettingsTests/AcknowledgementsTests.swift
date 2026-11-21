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

@Suite("DiagnosticsZipArchive")
struct DiagnosticsZipArchiveTests {
    @Test("IEEE 802.3 CRC-32 matches the standard test vector")
    func crc32StandardVector() {
        #expect(DiagnosticsZipArchive.crc32(Data("123456789".utf8)) == 0xcbf4_3926)
        #expect(DiagnosticsZipArchive.crc32(Data()) == 0x0000_0000)
    }

    @Test("builds a valid ZIP archive with local headers, central directory and EOCD")
    func buildsValidZip() throws {
        let entries = [
            DiagnosticsZipArchive.Entry(filename: "report.txt", text: "Halo 1.0 (1)\n"),
            DiagnosticsZipArchive.Entry(filename: "audit-events.jsonl", text: "{\"kind\":\"explained\"}\n"),
        ]
        let zip = DiagnosticsZipArchive.build(entries)
        // Local file header signature 0x04034b50 ("PK\x03\x04") at offset 0
        #expect(zip.count > 64)
        #expect(zip[0] == 0x50 && zip[1] == 0x4b && zip[2] == 0x03 && zip[3] == 0x04)
        // End of central directory signature 0x06054b50 ("PK\x05\x06") 22 bytes from the end
        let eocd = zip.count - 22
        #expect(zip[eocd] == 0x50 && zip[eocd + 1] == 0x4b && zip[eocd + 2] == 0x05 && zip[eocd + 3] == 0x06)
        // Entry count in EOCD (offset +8 and +10) == 2
        #expect(zip[eocd + 8] == 2 && zip[eocd + 10] == 2)
        // Stored payload bytes appear intact in the archive
        #expect(zip.range(of: Data("Halo 1.0 (1)\n".utf8)) != nil)
        #expect(zip.range(of: Data("{\"kind\":\"explained\"}\n".utf8)) != nil)
    }
}
