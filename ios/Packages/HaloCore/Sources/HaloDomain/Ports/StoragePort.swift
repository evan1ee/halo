import HaloFoundation

/// Reads SDK/app storage sizes, clears the media cache without touching keys or unsent messages, and applies retention policy (M20-13, D55).
public protocol StoragePort: Sendable {
    /// Current on-device byte breakdown from the SDK's `getStoreSizes()` and Halo's database.
    func storeSizes() async throws(HaloError) -> StoreSizeBreakdown

    /// Clears only cached media (never `cryptoStore`, `stateStore`, drafts, or unsent messages), then restores `retention`.
    func clearMediaCache(restoring retention: MediaCacheRetention) async throws(HaloError)

    /// Applies `retention` to the SDK's media cache immediately.
    func applyMediaRetention(_ retention: MediaCacheRetention) async throws(HaloError)
}
