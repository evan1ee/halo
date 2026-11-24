import Foundation
import HaloDomain
import HaloFoundation
import MatrixRustSDK
import Synchronization

/// `SyncPort` over the classic sync loop of `MatrixSessionPort` (D73, V-RS-7; SYNC_ENGINE §1). One status observer is kept for the port's life.
public final class MatrixSyncPort: SyncPort {
    private struct State {
        var status: SyncStatus = .idle
        var continuations: [UUID: AsyncStream<SyncStatus>.Continuation] = [:]
        var observer: UUID?
    }

    private let session: MatrixSessionPort
    private let state = Mutex(State())

    public init(session: MatrixSessionPort) { self.session = session }

    public func start() async throws(HaloError) {
        try await observe()
        try await session.startSync()
    }

    public func stop() async {
        await session.stopSync()
        // Stopping the service reports `.idle` or `.terminated` through the observer; a stop on a never-started
        // loop reports nothing, so settle the status here.
        if status == .idle || status == .running || status == .offline { publish(.stopped) }
    }

    public func syncOnce() async throws(HaloError) {
        try await session.syncOnce()
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

    // MARK: Internals

    private var status: SyncStatus { state.withLock { $0.status } }

    /// (Re)subscribes to the current sync service; the session (and its service) may have changed since the last start.
    private func observe() async throws(HaloError) {
        let handle = await session.observeSync { [weak self] status in self?.publish(status) }
        let previous = state.withLock { state in
            defer { state.observer = handle }
            return state.observer
        }
        if let previous { await session.unobserveSync(previous) }
    }

    private func publish(_ status: SyncStatus) {
        let continuations = state.withLock { state in
            state.status = status
            return Array(state.continuations.values)
        }
        for continuation in continuations { continuation.yield(status) }
    }
}
