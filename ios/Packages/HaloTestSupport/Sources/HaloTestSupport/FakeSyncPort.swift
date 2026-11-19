import Foundation
import HaloDomain
import HaloFoundation
import Synchronization

/// An in-memory `SyncPort`. `start()` moves to `.running`, `stop()` to `.stopped`; tests can push other states.
public final class FakeSyncPort: SyncPort {
    private struct State {
        var status: SyncStatus = .idle
        var startCalls = 0
        var stopCalls = 0
        var nextStartError: HaloError?
        var continuations: [UUID: AsyncStream<SyncStatus>.Continuation] = [:]
    }

    private let state = Mutex(State())

    public init() {}

    public var startCalls: Int { state.withLock { $0.startCalls } }
    public var stopCalls: Int { state.withLock { $0.stopCalls } }
    public var status: SyncStatus { state.withLock { $0.status } }

    public func failNextStart(with error: HaloError) { state.withLock { $0.nextStartError = error } }

    /// Sets the status as if the SDK had reported it (e.g. `.offline`, `.failed`).
    public func report(_ status: SyncStatus) { set(status) }

    public func start() async throws(HaloError) {
        let error: HaloError? = state.withLock { state in
            state.startCalls += 1
            defer { state.nextStartError = nil }
            return state.nextStartError
        }
        if let error { throw error }
        if status != .running { set(.running) }
    }

    public func stop() async {
        state.withLock { $0.stopCalls += 1 }
        if status != .stopped && status != .idle { set(.stopped) }
    }

    public func statuses() -> AsyncStream<SyncStatus> {
        let (stream, continuation) = AsyncStream<SyncStatus>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        let current = state.withLock { state in
            state.continuations[id] = continuation
            return state.status
        }
        continuation.yield(current)
        continuation.onTermination = { [weak self] _ in self?.state.withLock { _ = $0.continuations.removeValue(forKey: id) } }
        return stream
    }

    private func set(_ status: SyncStatus) {
        let continuations = state.withLock { state in
            state.status = status
            return Array(state.continuations.values)
        }
        for continuation in continuations { continuation.yield(status) }
    }
}
