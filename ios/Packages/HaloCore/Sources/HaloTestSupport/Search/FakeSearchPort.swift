import Foundation
import HaloDomain
import HaloFoundation
import Synchronization

/// In-memory `SearchPort` for unit testing `SearchCoordinator` and search UI without a homeserver.
public final class FakeSearchPort: SearchPort {
    private struct State {
        var corpus: [MessageSearchHit]
        var pageSize: Int
        var query: String = ""
        var loadedCount: Int = 0
        var nextError: HaloError?
        var continuations: [UUID: AsyncStream<SearchSnapshot>.Continuation] = [:]
    }

    private let state: Mutex<State>

    public init(corpus: [MessageSearchHit] = [], pageSize: Int = 20) {
        self.state = Mutex(State(corpus: corpus, pageSize: max(1, pageSize)))
    }

    public func failNext(with error: HaloError) {
        state.withLock { $0.nextError = error }
    }

    public func snapshots() -> AsyncStream<SearchSnapshot> {
        let (stream, continuation) = AsyncStream<SearchSnapshot>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        let initial = state.withLock { state -> SearchSnapshot in
            state.continuations[id] = continuation
            return Self.snapshot(from: state)
        }
        continuation.yield(initial)
        continuation.onTermination = { [weak self] _ in
            self?.state.withLock { _ = $0.continuations.removeValue(forKey: id) }
        }
        return stream
    }

    public func setQuery(_ query: String) async throws(HaloError) {
        let result: Result<(SearchSnapshot, [AsyncStream<SearchSnapshot>.Continuation]), HaloError> = state.withLock { state in
            if let error = state.nextError {
                state.nextError = nil
                return .failure(error)
            }
            state.query = query.trimmingCharacters(in: .whitespacesAndNewlines)
            state.loadedCount = state.query.isEmpty ? 0 : state.pageSize
            return .success((Self.snapshot(from: state), Array(state.continuations.values)))
        }
        let (snap, conts) = try result.get()
        for c in conts { c.yield(snap) }
    }

    public func loadMore() async throws(HaloError) {
        let result: Result<(SearchSnapshot, [AsyncStream<SearchSnapshot>.Continuation]), HaloError> = state.withLock { state in
            if let error = state.nextError {
                state.nextError = nil
                return .failure(error)
            }
            guard !state.query.isEmpty else {
                return .success((Self.snapshot(from: state), Array(state.continuations.values)))
            }
            state.loadedCount += state.pageSize
            return .success((Self.snapshot(from: state), Array(state.continuations.values)))
        }
        let (snap, conts) = try result.get()
        for c in conts { c.yield(snap) }
    }

    private static func snapshot(from state: State) -> SearchSnapshot {
        guard !state.query.isEmpty else { return .empty }
        let needle = state.query.lowercased()
        let matching = state.corpus.filter { $0.body.lowercased().contains(needle) }
        let shown = Array(matching.prefix(state.loadedCount))
        return SearchSnapshot(hits: shown, isLoading: false, hasMore: shown.count < matching.count)
    }
}
