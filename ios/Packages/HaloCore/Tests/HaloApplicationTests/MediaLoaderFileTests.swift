import Foundation
import HaloDomain
import HaloFoundation
import HaloTestSupport
import Testing
@testable import HaloApplication

@Suite("MediaLoader.file (M19-5)")
struct MediaLoaderFileTests {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("halo-file-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("the content lands as a file named by its last path component, and never leaves the folder")
    func writesInside() async throws {
        let port = FakeMediaPort()
        let ref = MediaRef(token: "doc")
        port.add(ref, data: Data("hello".utf8))
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try await MediaLoader(port: port).file(ref, name: "../../secret.pdf", mimeType: "application/pdf", in: dir)
        #expect(url.deletingLastPathComponent().standardizedFileURL == dir.standardizedFileURL)
        #expect(url.lastPathComponent == "secret.pdf")
        #expect(try Data(contentsOf: url) == Data("hello".utf8))
        let unnamed = try await MediaLoader(port: port).file(ref, name: "..", mimeType: nil, in: dir)
        #expect(unnamed.lastPathComponent == "file")
    }

    @Test("a missing file is not found; nothing is left behind")
    func missing() async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        await #expect(throws: HaloError.notFound) {
            _ = try await MediaLoader(port: FakeMediaPort()).file(MediaRef(token: "gone"), name: "x.bin", mimeType: nil, in: dir)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
    }

    @Test("cachedContent serves repeat reads and concurrent callers from one fetch (M19-5)")
    func cachedContentDeduplicatesAndCaches() async throws {
        let port = FakeMediaPort()
        let ref = MediaRef(token: "thumb-1")
        port.add(ref, data: Data("thumb-bytes".utf8))
        let loader = MediaLoader(port: port)

        async let first = loader.cachedContent(ref)
        async let second = loader.cachedContent(ref)
        let (a, b) = try await (first, second)
        #expect(a == Data("thumb-bytes".utf8))
        #expect(b == Data("thumb-bytes".utf8))
        #expect(port.contentCalls == 1)

        let third = try await loader.cachedContent(ref)
        #expect(third == Data("thumb-bytes".utf8))
        #expect(port.contentCalls == 1)
    }
}
