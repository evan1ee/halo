import Foundation
import HaloApplication
import HaloDomain
import HaloFoundation
import Observation

/// Drives search inside a single room with previous (older) / next (newer) match stepping (ROADMAP M20-11, MESSAGE_SEARCH FR-8).
///
/// Uses an independent `SearchCoordinator` scoped to `room` (`SearchQuery(text:room:)`) so global chat-list search is untouched,
/// jumps to matches through M20-1 (`TimelineViewModel.jump(toEvent:)`), and reflects per-room indexing/offline/error states.
@MainActor @Observable
public final class RoomSearchViewModel {
    /// A match located inside a thread: stepping jumps to `rootEvent` in the room timeline and offers opening the thread at `eventID`.
    public struct ThreadMatch: Equatable, Sendable {
        public let rootEvent: EventID
        public let eventID: EventID

        public init(rootEvent: EventID, eventID: EventID) {
            self.rootEvent = rootEvent
            self.eventID = eventID
        }
    }

    public private(set) var isPresented = false
    /// What the user has typed into the in-room search field.
    public var query = "" {
        didSet {
            if query != oldValue { queryChanged() }
        }
    }
    /// The trimmed query the current match list belongs to.
    public private(set) var searchedQuery = ""
    public private(set) var isLoading = false
    public private(set) var isLoadingMore = false
    public private(set) var isJumping = false
    public private(set) var errorMessage: String?
    public private(set) var indexNotice: RoomSearchIndexNotice?
    public private(set) var navigator = RoomSearchNavigator()

    public let room: RoomID
    private let coordinator: SearchCoordinator
    private let statuses: (@Sendable () async -> AsyncStream<SearchIndexStatus>)?
    private let roomCoverage: (@Sendable () async -> RoomSearchCoverage?)?
    private let jumpToEvent: @MainActor (EventID) async -> Bool
    private let locale: Locale

    private var observations: [Task<Void, Never>] = []
    private var pendingDispatch: (query: SearchQuery, now: Bool)?
    private var dispatchTask: Task<Void, Never>?
    private var jumpTask: Task<Void, Never>?
    private var loadMoreTask: Task<Void, Never>?
    private var lastStatus = SearchIndexStatus()
    private var lastCoverage: RoomSearchCoverage?

    public init(
        room: RoomID,
        coordinator: SearchCoordinator,
        statuses: (@Sendable () async -> AsyncStream<SearchIndexStatus>)? = nil,
        roomCoverage: (@Sendable () async -> RoomSearchCoverage?)? = nil,
        jumpToEvent: @escaping @MainActor (EventID) async -> Bool,
        locale: Locale = .current
    ) {
        self.room = room
        self.coordinator = coordinator
        self.statuses = statuses
        self.roomCoverage = roomCoverage
        self.jumpToEvent = jumpToEvent
        self.locale = locale
    }

    isolated deinit {
        dispatchTask?.cancel()
        jumpTask?.cancel()
        loadMoreTask?.cancel()
        for task in observations { task.cancel() }
    }

    // MARK: Derived state

    public var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var positionText: String? { navigator.positionText }
    public var canStepPrevious: Bool { !isLoadingMore && navigator.canStepPrevious }
    public var canStepNext: Bool { navigator.canStepNext }
    public var currentHit: MessageSearchHit? { navigator.currentHit }

    /// The timeline event currently highlighted in the room (a thread match highlights its thread root in the main timeline).
    public var highlightedEventID: EventID? {
        guard let hit = navigator.currentHit else { return nil }
        return hit.threadRoot ?? hit.eventID
    }

    /// Non-nil when the currently selected match belongs to a thread, so the bar can offer "Open thread".
    public var selectedThreadMatch: ThreadMatch? {
        guard let hit = navigator.currentHit, let root = hit.threadRoot else { return nil }
        return ThreadMatch(rootEvent: root, eventID: hit.eventID)
    }

    /// `true` when the settled query returned zero hits without an error.
    public var showsEmptyState: Bool {
        !trimmedQuery.isEmpty && !isLoading && errorMessage == nil && navigator.hits.isEmpty && searchedQuery == trimmedQuery
    }

    /// Human-readable empty state distinguishing a complete room from one still indexing.
    public var emptyStateText: String {
        indexNotice == nil ? "No matches" : "No matches so far"
    }

    // MARK: Lifecycle

    /// Presents the in-room search bar and begins observing search snapshots and indexing status.
    public func open() {
        guard !isPresented else { return }
        isPresented = true
        startObserving()
    }

    /// Dismisses the in-room search bar, stops observations, clears the active search query, and removes the highlight.
    public func close() {
        guard isPresented || !observations.isEmpty || !query.isEmpty else { return }
        isPresented = false
        cancelAllWork()
        query = ""
        searchedQuery = ""
        isLoading = false
        isLoadingMore = false
        isJumping = false
        errorMessage = nil
        navigator.reset()
        let coordinator = coordinator
        Task { await coordinator.clear() }
    }

    /// Submits the current query immediately (e.g. keyboard Search button or Retry).
    public func submit() {
        guard isPresented else { return }
        search(now: true)
    }

    /// Retries after a search error or unavailable index.
    public func retry() {
        errorMessage = nil
        search(now: true)
    }

    /// Clears only the text field while keeping the search bar open.
    public func clearQuery() {
        query = ""
    }

    // MARK: Stepping

    /// Steps to an older match (↑ in the timeline), automatically loading the next page when needed.
    public func stepPrevious() {
        guard isPresented, !isLoadingMore else { return }
        switch navigator.stepPrevious() {
        case .jump(let hit):
            performJump(to: hit)
        case .loadMore:
            loadMoreTask?.cancel()
            isLoadingMore = true
            let coordinator = coordinator
            loadMoreTask = Task { [weak self] in
                await coordinator.loadMore()
                guard let self, !Task.isCancelled else { return }
                self.isLoadingMore = false
                if self.errorMessage != nil {
                    self.navigator.cancelPendingLoadMore()
                }
            }
        case .none:
            break
        }
    }

    /// Steps to a newer match (↓ in the timeline).
    public func stepNext() {
        guard isPresented, let hit = navigator.stepNext() else { return }
        performJump(to: hit)
    }

    // MARK: Private

    private func startObserving() {
        guard observations.isEmpty else { return }
        let coordinator = coordinator
        observations.append(Task { [weak self] in
            let stream = await coordinator.snapshots()
            for await snapshot in stream {
                guard !Task.isCancelled else { return }
                self?.apply(snapshot)
            }
        })
        if let statuses {
            observations.append(Task { [weak self] in
                let stream = await statuses()
                for await status in stream {
                    guard !Task.isCancelled else { return }
                    await self?.apply(status)
                }
            })
        } else if roomCoverage != nil {
            observations.append(Task { [weak self] in
                await self?.refreshCoverage()
            })
        }
    }

    private func cancelAllWork() {
        pendingDispatch = nil
        dispatchTask?.cancel()
        dispatchTask = nil
        jumpTask?.cancel()
        jumpTask = nil
        loadMoreTask?.cancel()
        loadMoreTask = nil
        for task in observations { task.cancel() }
        observations.removeAll()
    }

    private func queryChanged() {
        guard isPresented else { return }
        loadMoreTask?.cancel()
        loadMoreTask = nil
        isLoadingMore = false
        search(now: false)
    }

    private func search(now: Bool) {
        let nextQuery = SearchQuery(text: query, room: room, filter: .all)
        pendingDispatch = (nextQuery, (pendingDispatch?.now ?? false) || now)
        guard dispatchTask == nil else { return }
        let coordinator = coordinator
        dispatchTask = Task { [weak self] in
            while let request = self?.takePendingDispatch() {
                await coordinator.search(request.query, now: request.now)
            }
            self?.dispatchTask = nil
        }
    }

    private func takePendingDispatch() -> (query: SearchQuery, now: Bool)? {
        defer { pendingDispatch = nil }
        return pendingDispatch
    }

    private func apply(_ snapshot: SearchCoordinator.Snapshot) {
        guard isPresented else { return }
        let queryText = snapshot.query.text
        if queryText.isEmpty {
            searchedQuery = ""
            isLoading = false
            isLoadingMore = false
            errorMessage = nil
            jumpTask?.cancel()
            jumpTask = nil
            isJumping = false
            navigator.reset()
            return
        }

        // Ignore snapshots that aren't scoped to this room.
        guard snapshot.query.room == room else { return }

        isLoading = snapshot.isLoading
        errorMessage = snapshot.error.map { Self.errorCopy(for: $0) }
        if snapshot.error != nil {
            isLoadingMore = false
            navigator.cancelPendingLoadMore()
        }

        // While a local query or next-page load is in flight, keep the current match list and pending step steady.
        if snapshot.isLoading {
            return
        }

        let queryChanged = queryText != searchedQuery
        searchedQuery = queryText
        if !snapshot.isLoading { isLoadingMore = false }
        if let targetHit = navigator.apply(hits: snapshot.hits, hasMore: snapshot.hasMore, queryChanged: queryChanged) {
            performJump(to: targetHit)
        }
    }

    private func apply(_ status: SearchIndexStatus) async {
        lastStatus = status
        await refreshCoverage()
    }

    private func refreshCoverage() async {
        if let roomCoverage {
            lastCoverage = await roomCoverage()
        }
        guard isPresented else { return }
        indexNotice = RoomSearchIndexNotice.describe(coverage: lastCoverage, status: lastStatus, locale: locale)
    }

    private func performJump(to hit: MessageSearchHit) {
        jumpTask?.cancel()
        let target = hit.threadRoot ?? hit.eventID
        isJumping = true
        jumpTask = Task { [weak self] in
            guard let self else { return }
            _ = await self.jumpToEvent(target)
            if !Task.isCancelled {
                self.isJumping = false
            }
        }
    }

    private static func errorCopy(for error: HaloError) -> String {
        switch error {
        case .storage(.unavailable):
            "Search isn't ready yet. Try again in a moment."
        default:
            "Search couldn't complete."
        }
    }
}
