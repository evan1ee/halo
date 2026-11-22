import HaloDomain
import HaloFoundation

/// Drives interactive message search over `SearchPort` (M8 Search + Saved, V-SEARCH-1).
public actor SearchCoordinator {
    public struct Snapshot: Sendable, Equatable {
        public let query: String
        public let hits: [MessageSearchHit]
        public let isLoading: Bool
        public let hasMore: Bool
        public let error: HaloError?

        public init(query: String, hits: [MessageSearchHit], isLoading: Bool, hasMore: Bool, error: HaloError?) {
            self.query = query
            self.hits = hits
            self.isLoading = isLoading
            self.hasMore = hasMore
            self.error = error
        }

        public static let empty = Snapshot(query: "", hits: [], isLoading: false, hasMore: false, error: nil)
    }

    public private(set) var snapshot: Snapshot = .empty {
        didSet { if snapshot != oldValue { broadcaster.publish(snapshot) } }
    }

    private let port: any SearchPort
    private var broadcaster = SnapshotBroadcaster<Snapshot>()
    private var streamTask: Task<Void, Never>?

    public init(port: any SearchPort) {
        self.port = port
    }

    deinit {
        streamTask?.cancel()
    }

    public func snapshots() -> AsyncStream<Snapshot> {
        broadcaster.subscribe(current: snapshot)
    }

    public func begin() {
        guard streamTask == nil else { return }
        let stream = port.snapshots()
        streamTask = Task { [weak self] in
            for await portSnap in stream {
                await self?.apply(portSnap)
            }
        }
    }

    public func search(_ query: String) async {
        begin()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        snapshot = Snapshot(query: trimmed, hits: trimmed.isEmpty ? [] : snapshot.hits, isLoading: !trimmed.isEmpty, hasMore: false, error: nil)
        do {
            try await port.setQuery(trimmed)
        } catch {
            snapshot = Snapshot(query: trimmed, hits: [], isLoading: false, hasMore: false, error: error)
        }
    }

    public func loadMore() async {
        guard snapshot.hasMore, !snapshot.isLoading else { return }
        do {
            try await port.loadMore()
        } catch {
            snapshot = Snapshot(query: snapshot.query, hits: snapshot.hits, isLoading: false, hasMore: snapshot.hasMore, error: error)
        }
    }

    public func clear() async {
        await search("")
    }

    private func apply(_ portSnap: SearchSnapshot) {
        snapshot = Snapshot(
            query: snapshot.query,
            hits: portSnap.hits,
            isLoading: portSnap.isLoading,
            hasMore: portSnap.hasMore,
            error: nil)
    }
}
