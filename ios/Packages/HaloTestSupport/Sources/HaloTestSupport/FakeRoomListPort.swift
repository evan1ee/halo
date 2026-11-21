import Foundation
import HaloDomain
import HaloFoundation
import Synchronization

/// An in-memory room list implementing `RoomListPort`. Every subscription starts with a `.reset`
/// of the current list (the port's contract), then receives the diffs passed to `emit`.
public final class FakeRoomListPort: RoomListPort {
    private struct State {
        var rooms: [RoomSummary] = []
        var filter: RoomListFilter = .all
        var continuations: [UUID: AsyncStream<RoomListDiff>.Continuation] = [:]
        var leftContinuations: [UUID: AsyncStream<Set<RoomID>>.Continuation] = [:]
        var syncContinuations: [UUID: AsyncStream<Set<RoomID>>.Continuation] = [:]
        var loadMoreCalls = 0
        var subscriptions = 0
    }

    private let state = Mutex(State())

    public init(rooms: [RoomSummary] = []) {
        state.withLock { $0.rooms = rooms }
    }

    /// Applies `diff` to the fake's list and sends it to every subscriber. Sending a diff that
    /// doesn't fit (to test the consumer's recovery) is allowed with `validate: false`.
    public func emit(_ diff: RoomListDiff, validate: Bool = true) throws(HaloError) {
        let continuations: [AsyncStream<RoomListDiff>.Continuation] = try state.withLock { (state) throws(HaloError) in
            var rooms = state.rooms
            if validate { try RoomListReducer.apply(diff, to: &rooms) }
            state.rooms = rooms
            return Array(state.continuations.values)
        }
        for continuation in continuations { continuation.yield(diff) }
    }

    /// Ends every open subscription, as when sync stops.
    public func finishSubscriptions() {
        for continuation in state.withLock({ Array($0.continuations.values) }) { continuation.finish() }
        for continuation in state.withLock({ Array($0.leftContinuations.values) }) { continuation.finish() }
        for continuation in state.withLock({ Array($0.syncContinuations.values) }) { continuation.finish() }
    }

    /// Reports rooms that were left/kicked/banned in sync (`rooms.left`).
    public func emitLeft(_ rooms: Set<RoomID>) {
        guard !rooms.isEmpty else { return }
        for continuation in state.withLock({ Array($0.leftContinuations.values) }) { continuation.yield(rooms) }
    }

    /// Reports that a sync response has completed with the given joined/invited room IDs (defaults to the current list).
    public func emitSyncComplete(present: Set<RoomID>? = nil) {
        let (ids, continuations) = state.withLock { state in
            (present ?? Set(state.rooms.map(\.id)), Array(state.syncContinuations.values))
        }
        for continuation in continuations { continuation.yield(ids) }
    }

    public var currentFilter: RoomListFilter { state.withLock { $0.filter } }
    public var loadMoreCalls: Int { state.withLock { $0.loadMoreCalls } }
    public var subscriptionCount: Int { state.withLock { $0.subscriptions } }

    // MARK: RoomListPort

    public func rooms(filter: RoomListFilter) -> AsyncStream<RoomListDiff> {
        let (stream, continuation) = AsyncStream<RoomListDiff>.makeStream(bufferingPolicy: .unbounded)
        let id = UUID()
        let current = state.withLock { state in
            state.filter = filter
            state.subscriptions += 1
            state.continuations[id] = continuation
            return state.rooms
        }
        continuation.yield(.reset(current))
        continuation.onTermination = { [weak self] _ in self?.state.withLock { _ = $0.continuations.removeValue(forKey: id) } }
        return stream
    }

    public func loadMore() async throws(HaloError) {
        state.withLock { $0.loadMoreCalls += 1 }
    }

    public func setFilter(_ filter: RoomListFilter) async throws(HaloError) {
        state.withLock { $0.filter = filter }
    }

    public func leftRooms() -> AsyncStream<Set<RoomID>> {
        let (stream, continuation) = AsyncStream<Set<RoomID>>.makeStream(bufferingPolicy: .unbounded)
        let id = UUID()
        state.withLock { $0.leftContinuations[id] = continuation }
        continuation.onTermination = { [weak self] _ in self?.state.withLock { _ = $0.leftContinuations.removeValue(forKey: id) } }
        return stream
    }

    public func syncCompletions() -> AsyncStream<Set<RoomID>> {
        let (stream, continuation) = AsyncStream<Set<RoomID>>.makeStream(bufferingPolicy: .unbounded)
        let id = UUID()
        state.withLock { $0.syncContinuations[id] = continuation }
        continuation.onTermination = { [weak self] _ in self?.state.withLock { _ = $0.syncContinuations.removeValue(forKey: id) } }
        return stream
    }
}
