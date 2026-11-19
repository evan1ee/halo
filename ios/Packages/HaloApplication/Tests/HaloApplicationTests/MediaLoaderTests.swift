import Foundation
import HaloDomain
import HaloFoundation
import HaloTestSupport
import Testing
@testable import HaloApplication

@Suite("MediaLoader")
struct MediaLoaderTests {
    private func port(_ items: [String: Int]) -> (FakeMediaPort, [MediaRef]) {
        let port = FakeMediaPort()
        var refs: [MediaRef] = []
        for (name, size) in items.sorted(by: { $0.key < $1.key }) {
            let ref = MediaRef(token: name)
            port.add(ref, data: Data(count: size))
            refs.append(ref)
        }
        return (port, refs)
    }

    @Test("the second request for the same thumbnail comes from the cache")
    func caches() async throws {
        let (port, refs) = port(["a": 10])
        let loader = MediaLoader(port: port)
        let first = try await loader.thumbnail(refs[0], width: 64, height: 64)
        let second = try await loader.thumbnail(refs[0], width: 64, height: 64)
        #expect(first == second)
        #expect(port.thumbnailCalls == 1)
        _ = try await loader.thumbnail(refs[0], width: 128, height: 128)  // another size is another entry
        #expect(port.thumbnailCalls == 2)
    }

    @Test("concurrent requests for one thumbnail share a single download")
    func dedupes() async throws {
        let (port, refs) = port(["a": 10])
        let loader = MediaLoader(port: port)
        let ref = refs[0]
        try await withThrowingTaskGroup(of: Data.self) { group in
            for _ in 0..<8 { group.addTask { try await loader.thumbnail(ref, width: 64, height: 64) } }
            for try await _ in group {}
        }
        #expect(port.thumbnailCalls == 1)
    }

    @Test("the least recently used entries are evicted when the byte limit is exceeded")
    func evicts() async throws {
        let (port, refs) = port(["a": 40, "b": 40, "c": 40])
        let loader = MediaLoader(port: port, byteLimit: 100)
        _ = try await loader.thumbnail(refs[0], width: 1, height: 1)
        _ = try await loader.thumbnail(refs[1], width: 1, height: 1)
        _ = try await loader.thumbnail(refs[0], width: 1, height: 1)  // a is now the most recent
        _ = try await loader.thumbnail(refs[2], width: 1, height: 1)  // evicts b
        #expect(port.thumbnailCalls == 3)
        _ = try await loader.thumbnail(refs[0], width: 1, height: 1)
        #expect(port.thumbnailCalls == 3)  // a survived
        _ = try await loader.thumbnail(refs[1], width: 1, height: 1)
        #expect(port.thumbnailCalls == 4)  // b was evicted
    }

    @Test("a failed download is reported and not cached, so a retry downloads again")
    func failures() async throws {
        let (port, refs) = port(["a": 10])
        let loader = MediaLoader(port: port)
        port.failNext(with: .network(retryable: true))
        await #expect(throws: HaloError.network(retryable: true)) { try await loader.thumbnail(refs[0], width: 1, height: 1) }
        _ = try await loader.thumbnail(refs[0], width: 1, height: 1)
        #expect(port.thumbnailCalls == 2)
        await #expect(throws: HaloError.notFound) { try await loader.thumbnail(MediaRef(token: "gone"), width: 1, height: 1) }
    }
}
