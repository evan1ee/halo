import HaloApplication
import HaloDomain
import HaloFoundation
import HaloTestSupport
import Synchronization
import Testing

@Suite("StorageCoordinator (SETTINGS §3, AC-SET-3, D55, M20-13)")
struct StorageCoordinatorTests {
    @Test("clearMediaCache clears memory caches, passes active retention, frees media, and leaves keys/messages/db intact")
    func clearMediaCacheFlow() async throws {
        let initial = StoreSizeBreakdown(
            mediaCacheBytes: 100 * 1_048_576,
            messagesBytes: 40 * 1_048_576,
            cryptoKeysBytes: 8 * 1_048_576,
            haloDatabaseBytes: 3 * 1_048_576
        )
        let port = FakeStoragePort(breakdown: initial, remainingMediaAfterClear: 1_024)
        let memoryCleared = Mutex(0)
        let retention = MediaCacheRetention(maxSize: .mb500, expiry: .days7)
        let coordinator = StorageCoordinator(
            port: port,
            currentRetention: { retention },
            clearMemoryCaches: { memoryCleared.withLock { $0 += 1 } }
        )

        let result = try await coordinator.clearMediaCache()
        #expect(memoryCleared.withLock { $0 } == 1)
        #expect(port.clearCalls == [retention])
        #expect(result.beforeMediaBytes == initial.mediaCacheBytes)
        #expect(result.afterMediaBytes == 1_024)
        #expect(result.freedBytes == initial.mediaCacheBytes - 1_024)
        #expect(result.breakdown.cryptoKeysBytes == initial.cryptoKeysBytes)
        #expect(result.breakdown.messagesBytes == initial.messagesBytes)
        #expect(result.breakdown.haloDatabaseBytes == initial.haloDatabaseBytes)
    }

    @Test("applyRetention forwards to port and propagates errors")
    func applyRetentionAndErrors() async throws {
        let port = FakeStoragePort()
        let coordinator = StorageCoordinator(port: port)
        let next = MediaCacheRetention(maxSize: .gb2, expiry: .days90)
        try await coordinator.applyRetention(next)
        #expect(port.appliedRetentions == [next])

        port.failNext(with: .storage(.corrupted))
        await #expect(throws: HaloError.storage(.corrupted)) {
            try await coordinator.applyRetention(.defaultPolicy)
        }
    }
}
