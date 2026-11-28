import HaloDomain
import HaloFoundation
import Synchronization

/// Controllable in-memory `StoragePort` for unit and view-model tests (M20-13).
public final class FakeStoragePort: StoragePort, Sendable {
    private struct State {
        var breakdown: StoreSizeBreakdown
        var appliedRetentions: [MediaCacheRetention] = []
        var clearCalls: [MediaCacheRetention] = []
        var nextError: HaloError?
        var remainingMediaAfterClear: Int64 = 0
    }

    private let state: Mutex<State>

    public init(
        breakdown: StoreSizeBreakdown = StoreSizeBreakdown(
            mediaCacheBytes: 120 * 1_048_576,
            messagesBytes: 45 * 1_048_576,
            cryptoKeysBytes: 8 * 1_048_576,
            haloDatabaseBytes: 2 * 1_048_576
        ),
        remainingMediaAfterClear: Int64 = 0
    ) {
        state = Mutex(State(breakdown: breakdown, remainingMediaAfterClear: remainingMediaAfterClear))
    }

    public var appliedRetentions: [MediaCacheRetention] { state.withLock { $0.appliedRetentions } }
    public var clearCalls: [MediaCacheRetention] { state.withLock { $0.clearCalls } }
    public var currentBreakdown: StoreSizeBreakdown { state.withLock { $0.breakdown } }

    public func failNext(with error: HaloError?) { state.withLock { $0.nextError = error } }

    public func setBreakdown(_ breakdown: StoreSizeBreakdown) {
        state.withLock { $0.breakdown = breakdown }
    }

    public func storeSizes() async throws(HaloError) -> StoreSizeBreakdown {
        try state.withLock { state throws(HaloError) in
            if let error = state.nextError {
                state.nextError = nil
                throw error
            }
            return state.breakdown
        }
    }

    public func clearMediaCache(restoring retention: MediaCacheRetention) async throws(HaloError) {
        try state.withLock { state throws(HaloError) in
            if let error = state.nextError {
                state.nextError = nil
                throw error
            }
            state.clearCalls.append(retention)
            state.appliedRetentions.append(retention)
            state.breakdown = StoreSizeBreakdown(
                mediaCacheBytes: state.remainingMediaAfterClear,
                messagesBytes: state.breakdown.messagesBytes,
                cryptoKeysBytes: state.breakdown.cryptoKeysBytes,
                haloDatabaseBytes: state.breakdown.haloDatabaseBytes
            )
        }
    }

    public func applyMediaRetention(_ retention: MediaCacheRetention) async throws(HaloError) {
        try state.withLock { state throws(HaloError) in
            if let error = state.nextError {
                state.nextError = nil
                throw error
            }
            state.appliedRetentions.append(retention)
        }
    }
}
