import Foundation
import HaloDomain
import HaloFoundation

/// Drives one message search (MESSAGE_SEARCH §6): returns local cached hits immediately on query entry without waiting on the network,
/// then progressively verifies stale hits and streams newly indexed remote Matrix messages in the background. A result always belongs to
/// the query it is shown for: outdated searches are cancelled and stale answers are dropped, and only one next-page request runs at a time (GA-32).
public actor SearchCoordinator {
    public typealias Sleep = @Sendable (Duration) async throws -> Void
    /// Pause in typing before remote server verification and remote history prioritization run; local index queries run immediately.
    public static let remoteDebounce: Duration = .milliseconds(150)
    public static let debounce: Duration = remoteDebounce

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
    private let onRemoteQuery: (@Sendable (SearchQuery?) async -> Void)?
    private var broadcaster = SnapshotBroadcaster<Snapshot>()
    private var next: SearchCursor?
    private var running: Task<Void, Never>?
    private var paging: Task<Void, Never>?
    private var recheckingPages: [UUID: Task<Void, Never>] = [:]
    private var refreshing: Task<Void, Never>?
    private var needsAnotherRefresh = false
    private var generation = 0

    public init(
        port: any SearchPort,
        onRemoteQuery: (@Sendable (SearchQuery?) async -> Void)? = nil,
        sleep: @escaping Sleep = { try await Task.sleep(for: $0) }
    ) {
        self.port = port
        self.onRemoteQuery = onRemoteQuery
        self.sleep = sleep
    }

    deinit {
        running?.cancel()
        paging?.cancel()
        for task in recheckingPages.values { task.cancel() }
        refreshing?.cancel()
    }

    public func snapshots() -> AsyncStream<Snapshot> { broadcaster.subscribe(current: snapshot) }

    /// Searches local cache immediately for `query`, then runs remote verification and remote backfill after typing pauses (or at once if `now`).
    public func search(_ query: SearchQuery, now: Bool = false) {
        var query = query
        query.text = query.text.trimmingCharacters(in: .whitespacesAndNewlines)
        generation += 1
        cancelTasks()
        next = nil
        guard !query.text.isEmpty else {
            snapshot = .empty
            if let onRemoteQuery { Task { await onRemoteQuery(nil) } }
            return
        }
        // Rows from another room or filter aren't results of this query; rows from the previous text stay steady until local hits arrive.
        let keeps = snapshot.query.room == query.room && snapshot.query.filter == query.filter
        snapshot = Snapshot(query: query, hits: keeps ? snapshot.hits : [], isLoading: true, hasMore: false, error: nil)
        let current = generation
        let wait = sleep
        running = Task { [weak self] in
            await self?.runSearch(query, now: now, generation: current, wait: wait)
        }
    }

    /// Loads the next page immediately from the local index and verifies stale hits progressively in the background; single-flight per query.
    public func loadMore() async {
        guard let cursor = next, paging == nil, !snapshot.isLoading else { return }
        snapshot.isLoading = true
        snapshot.error = nil
        let current = generation, query = snapshot.query
        let task = Task { [weak self] in
            guard let self else { return }
            await self.runLoadMore(query, after: cursor, generation: current)
        }
        paging = task
        await task.value
    }

    /// The index changed (remote history slice or live sync batch): updates displayed results progressively without a loading spinner or page truncation.
    public func refresh(in touchedRooms: Set<RoomID> = []) async {
        guard !snapshot.query.text.isEmpty, snapshot.error == nil else { return }
        if let targetRoom = snapshot.query.room, !touchedRooms.isEmpty, !touchedRooms.contains(targetRoom) { return }
        guard refreshing == nil else {
            needsAnotherRefresh = true
            return
        }
        let task = Task<Void, Never> { [weak self] in
            await self?.runRefreshLoop()
        }
        refreshing = task
        await task.value
    }

    public func clear() { search(SearchQuery(text: "")) }

    // MARK: Execution

    private func cancelTasks() {
        running?.cancel()
        running = nil
        paging?.cancel()
        paging = nil
        for task in recheckingPages.values { task.cancel() }
        recheckingPages.removeAll()
        refreshing?.cancel()
        refreshing = nil
        needsAnotherRefresh = false
    }

    private func runSearch(_ query: SearchQuery, now: Bool, generation: Int, wait: Sleep) async {
        guard generation == self.generation, !Task.isCancelled else { return }
        let localPage: SearchPage
        do {
            localPage = try await port.searchLocal(query, after: nil)
        } catch {
            guard generation == self.generation else { return }
            snapshot = Snapshot(query: query, hits: [], isLoading: false, hasMore: false, error: error == .cancelled ? nil : error)
            return
        }
        guard generation == self.generation, !Task.isCancelled else { return }
        next = localPage.next
        snapshot = Snapshot(query: query, hits: localPage.hits, isLoading: false, hasMore: localPage.next != nil, error: nil)

        if !now {
            do { try await wait(Self.remoteDebounce) } catch { return }
        }
        guard generation == self.generation, !Task.isCancelled else { return }
        if let onRemoteQuery {
            await onRemoteQuery(query)
        }
        guard generation == self.generation, !Task.isCancelled else { return }
        await verifySlice(localPage.hits, generation: generation)
    }

    private func runLoadMore(_ query: SearchQuery, after cursor: SearchCursor, generation: Int) async {
        defer { if generation == self.generation { paging = nil } }
        guard generation == self.generation, !Task.isCancelled else { return }
        do {
            let page = try await port.searchLocal(query, after: cursor)
            guard generation == self.generation, !Task.isCancelled else { return }
            next = page.next
            let known = Set(snapshot.hits.map(\.id))
            let added = page.hits.filter { !known.contains($0.id) }
            snapshot = Snapshot(
                query: query, hits: snapshot.hits + added,
                isLoading: false, hasMore: page.next != nil, error: nil)
            if !added.isEmpty {
                let id = UUID()
                recheckingPages[id] = Task { [weak self] in
                    await self?.verifySlice(added, generation: generation)
                    await self?.finishRecheck(id)
                }
            }
        } catch {
            guard generation == self.generation else { return }
            snapshot = Snapshot(query: query, hits: snapshot.hits, isLoading: false, hasMore: true, error: error == .cancelled ? nil : error)
        }
    }

    private func finishRecheck(_ id: UUID) {
        recheckingPages.removeValue(forKey: id)
    }

    private func verifySlice(_ slice: [MessageSearchHit], generation: Int) async {
        guard !slice.isEmpty, generation == self.generation, !Task.isCancelled else { return }
        guard let deltas = try? await port.recheck(slice), !deltas.isEmpty else { return }  // best-effort: offline or cancelled keeps local cached rows
        guard generation == self.generation, !Task.isCancelled else { return }
        let updated = snapshot.hits.compactMap { hit -> MessageSearchHit? in
            switch deltas[hit.id] {
            case .gone: return nil
            case .edited(let content):
                return MessageSearchHit(
                    roomID: hit.roomID, eventID: hit.eventID, threadRoot: hit.threadRoot,
                    senderID: hit.senderID, senderName: hit.senderName,
                    body: content.body, timestamp: hit.timestamp, kind: content.kind, attachment: content.attachment)
            case .unchanged, .unchecked, nil:
                return hit
            }
        }
        snapshot.hits = updated
        if updated.isEmpty, next != nil, paging == nil, !snapshot.isLoading {
            await loadMore()
        }
    }

    private func runRefreshLoop() async {
        defer { refreshing = nil }
        repeat {
            needsAnotherRefresh = false
            let current = generation
            let query = snapshot.query
            guard !query.text.isEmpty, snapshot.error == nil, !Task.isCancelled else { return }
            // Wait if an explicit initial load or loadMore is mid-flight so we merge onto its settled count.
            if snapshot.isLoading {
                await Task.yield()
                if snapshot.isLoading { return }
            }
            let targetCount = max(LocalMessageSearch.pageSize, snapshot.hits.count)
            var collected: [MessageSearchHit] = []
            var seen: Set<String> = []
            var cursor: SearchCursor?
            var reachedEnd = false
            while collected.count < targetCount {
                guard current == self.generation, !Task.isCancelled else { return }
                guard let page = try? await port.searchLocal(query, after: cursor) else { return }  // best-effort: next write retries
                for hit in page.hits where seen.insert(hit.id).inserted {
                    collected.append(hit)
                }
                cursor = page.next
                if cursor == nil || page.hits.isEmpty {
                    reachedEnd = true
                    break
                }
            }
            guard current == self.generation, !Task.isCancelled, !snapshot.isLoading else { return }
            next = cursor
            snapshot = Snapshot(query: query, hits: collected, isLoading: false, hasMore: !reachedEnd && cursor != nil, error: nil)
        } while needsAnotherRefresh && !Task.isCancelled
    }
}
