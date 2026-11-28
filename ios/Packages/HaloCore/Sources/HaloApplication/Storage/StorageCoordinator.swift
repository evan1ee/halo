import HaloDomain
import HaloFoundation

/// Coordinates storage measurements, media cache clearing, and media retention policy updates (SETTINGS §3, D55, M20-13).
public actor StorageCoordinator {
    private let port: any StoragePort
    private let currentRetention: @Sendable () async -> MediaCacheRetention
    private let clearMemoryCaches: @Sendable () async -> Void
    private var isClearing = false

    public init(
        port: any StoragePort,
        currentRetention: @escaping @Sendable () async -> MediaCacheRetention = { .defaultPolicy },
        clearMemoryCaches: @escaping @Sendable () async -> Void = {}
    ) {
        self.port = port
        self.currentRetention = currentRetention
        self.clearMemoryCaches = clearMemoryCaches
    }

    /// Reads current on-device store sizes.
    public func sizes() async throws(HaloError) -> StoreSizeBreakdown {
        try await port.storeSizes()
    }

    /// Clears in-memory and SDK media caches without touching encryption keys, drafts, or unsent messages (AC-SET-3).
    public func clearMediaCache() async throws(HaloError) -> MediaCacheClearResult {
        guard !isClearing else { throw .cancelled }
        isClearing = true
        defer { isClearing = false }
        let before = try await port.storeSizes()
        let retention = await currentRetention()
        await clearMemoryCaches()
        try await port.clearMediaCache(restoring: retention)
        let after = try await port.storeSizes()
        return MediaCacheClearResult(
            beforeMediaBytes: before.mediaCacheBytes,
            afterMediaBytes: after.mediaCacheBytes,
            breakdown: after
        )
    }

    /// Applies a new media cache retention policy to the SDK media store.
    public func applyRetention(_ retention: MediaCacheRetention) async throws(HaloError) {
        try await port.applyMediaRetention(retention)
    }
}
