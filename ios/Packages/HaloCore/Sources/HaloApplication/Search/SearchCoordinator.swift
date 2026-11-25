import Foundation
import HaloDomain
import HaloFoundation

/// Drives one message search: waits until typing pauses, then asks `SearchPort` (MESSAGE_SEARCH §6). A result always belongs to the query
/// it is shown for: an answer to an earlier query is dropped, and only one page loads at a time (GA-32).
public actor SearchCoordinator {
    public typealias Sleep = @Sendable (Duration) async throws -> Void
    public static let debounce: Duration = .milliseconds(250)

    public struct Snapshot: Sendable, Equatable {
        public var query: SearchQuery
        public var hits: [MessageSearchHit]
        public var isLoading: Bool
        public var hasMore: Bool
        public var error: HaloError?

        public static let empty = Snapshot(query: SearchQuery(text: ""), hits: [], isLoading: false, hasMore: false, error: nil)
    }

    public private(set) var snapshot: Snapshot = .empty {
        didSet { if snapshot != oldValue { broadcaster.publish(snapshot) } }
    }

    private let port: any SearchPort
    private let sleep: Sleep
    private var broadcaster = SnapshotBroadcaster<Snapshot>()
    private var next: SearchCursor?
    private var running: Task<Void, Never>?
    private var generation = 0

    public init(port: any SearchPort, sleep: @escaping Sleep = { try await Task.sleep(for: $0) }) {
        self.port = port
        self.sleep = sleep
    }

    deinit { running?.cancel() }

    public func snapshots() -> AsyncStream<Snapshot> { broadcaster.subscribe(current: snapshot) }

    /// Searches for `query`, after a pause in typing unless `now`. The results of the query before stay on screen while this one loads.
    public func search(_ query: SearchQuery, now: Bool = false) {
        var query = query
        query.text = query.text.trimmingCharacters(in: .whitespacesAndNewlines)
        generation += 1
        running?.cancel()
        next = nil
        guard !query.text.isEmpty else {
            running = nil
            snapshot = .empty
            return
        }
        // The rows of another room or kind aren't results of this query; those of an earlier text are only older.
        let keeps = snapshot.query.room == query.room && snapshot.query.filter == query.filter
        snapshot = Snapshot(query: query, hits: keeps ? snapshot.hits : [], isLoading: true, hasMore: false, error: nil)
        let current = generation
        let wait = sleep
        running = Task { [weak self] in
            if !now { do { try await wait(Self.debounce) } catch { return } }
            await self?.load(query, after: nil, generation: current)
        }
    }

    /// Loads the next page; does nothing while one loads.
    public func loadMore() async {
        guard let next, !snapshot.isLoading else { return }
        snapshot.isLoading = true
        snapshot.error = nil
        let current = generation, query = snapshot.query
        let task = Task { [weak self] in
            guard let self else { return }
            await self.load(query, after: next, generation: current)
        }
        running = task
        await task.value
    }

    /// The index grew: looks again for the shown query, without a spinner. Only while everything found is on screen.
    public func refresh() async {
        guard !snapshot.query.text.isEmpty, !snapshot.isLoading, next == nil, snapshot.error == nil else { return }
        await load(snapshot.query, after: nil, generation: generation)
    }

    public func clear() { search(SearchQuery(text: "")) }

    private func load(_ query: SearchQuery, after cursor: SearchCursor?, generation: Int) async {
        guard generation == self.generation, !Task.isCancelled else { return }
        do {
            let page = try await port.search(query, after: cursor)
            guard generation == self.generation else { return }
            next = page.next
            let known = Set(cursor == nil ? [] : snapshot.hits.map(\.id))
            snapshot = Snapshot(
                query: query, hits: cursor == nil ? page.hits : snapshot.hits + page.hits.filter { !known.contains($0.id) },
                isLoading: false, hasMore: page.next != nil, error: nil)
        } catch {
            guard generation == self.generation else { return }
            snapshot = Snapshot(query: query, hits: cursor == nil ? [] : snapshot.hits, isLoading: false, hasMore: cursor != nil, error: error == .cancelled ? nil : error)
        }
    }
}
