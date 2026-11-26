import Foundation
import HaloApplication
import HaloDomain
import HaloFoundation
import Observation

/// Message search across all rooms, below the chat names (MESSAGE_SEARCH §5).
@MainActor @Observable
public final class MessageSearchViewModel {
    public struct ResultRow: Equatable, Identifiable, Sendable {
        public let id: String
        public let roomID: RoomID
        public let eventID: EventID
        public let threadRoot: EventID?
        public let roomName: String
        public let roomAvatar: MediaRef?
        public let sender: String
        public let senderHighlights: [Range<Int>]
        /// The part of the message around the match, and where it matches.
        public let snippet: String
        public let highlights: [Range<Int>]
        public let kind: SearchKind
        public let attachment: SearchAttachment?
        public let timestamp: Date
        public let formattedTime: String

        public init(
            id: String, roomID: RoomID, eventID: EventID, threadRoot: EventID?, roomName: String,
            roomAvatar: MediaRef? = nil, sender: String, senderHighlights: [Range<Int>] = [],
            snippet: String, highlights: [Range<Int>], kind: SearchKind, attachment: SearchAttachment? = nil,
            timestamp: Date, formattedTime: String? = nil
        ) {
            self.id = id
            self.roomID = roomID
            self.eventID = eventID
            self.threadRoot = threadRoot
            self.roomName = roomName
            self.roomAvatar = roomAvatar
            self.sender = sender
            self.senderHighlights = senderHighlights
            self.snippet = snippet
            self.highlights = highlights
            self.kind = kind
            self.attachment = attachment
            self.timestamp = timestamp
            self.formattedTime = formattedTime ?? Self.formatTime(timestamp)
        }

        /// Apple Messages-style relative date: time today, `"Yesterday"`, weekday within the past week, `"Nov 12"` this year, else `"Nov 12, 2025"`.
        public nonisolated static func formatTime(_ date: Date, now: Date = .now, calendar: Calendar = .current) -> String {
            if calendar.isDate(date, inSameDayAs: now) {
                return date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, calendar: calendar, timeZone: calendar.timeZone))
            }
            if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
                return "Yesterday"
            }
            let startOfToday = calendar.startOfDay(for: now)
            if let weekAgo = calendar.date(byAdding: .day, value: -6, to: startOfToday), date >= weekAgo, date < startOfToday {
                return date.formatted(Date.FormatStyle(calendar: calendar, timeZone: calendar.timeZone).weekday(.wide))
            }
            let style = Date.FormatStyle(calendar: calendar, timeZone: calendar.timeZone)
            if calendar.isDate(date, equalTo: now, toGranularity: .year) {
                return date.formatted(style.day().month(.abbreviated))
            }
            return date.formatted(style.day().month(.abbreviated).year())
        }
    }

    /// How far back the search reaches (FR-13); `nil` when every chat is read to its start and nothing is missing.
    public struct Coverage: Equatable, Sendable {
        public let text: String
        /// Messages that can't be decrypted on this device.
        public let undecryptable: Int
        public let canVerify: Bool
    }

    /// What is typed. Local index results appear immediately; remote checks and history follow after typing pauses.
    public var query = "" { didSet { if query != oldValue { queryChanged() } } }
    public var room: RoomID? { didSet { if room != oldValue { search(now: true) } } }
    public var filter: SearchFilter = .all { didSet { if filter != oldValue { search(now: true) } } }
    /// The query the rows belong to.
    public private(set) var searchedQuery = ""
    public private(set) var rows: [ResultRow] = []
    public private(set) var isLoading = false
    public private(set) var hasMore = false
    public private(set) var errorMessage: String?
    public private(set) var coverage: Coverage?

    private let coordinator: SearchCoordinator
    private let roomName: @MainActor (RoomID) -> String
    private let roomAvatar: @MainActor (RoomID) -> MediaRef?
    private let thumbnailLoader: (@Sendable (MediaRef, Int) async -> Data?)?
    private let statuses: (@Sendable () async -> AsyncStream<SearchIndexStatus>)?
    private let needsVerification: @MainActor () -> Bool
    private let onActivity: @MainActor () -> Void
    private var observations: [Task<Void, Never>] = []
    private var pendingDispatch: (query: SearchQuery, now: Bool)?
    private var dispatchTask: Task<Void, Never>?
    @ObservationIgnored private var thumbnailMemory: [MediaRef: Data] = [:]

    /// - Parameters:
    ///   - statuses: what the indexer is doing, for the coverage notice.
    ///   - needsVerification: verifying this device could make more messages readable.
    ///   - onActivity: optional hook when the user interacts with search.
    public init(
        coordinator: SearchCoordinator,
        roomName: @escaping @MainActor (RoomID) -> String,
        roomAvatar: @escaping @MainActor (RoomID) -> MediaRef? = { _ in nil },
        thumbnail: (@Sendable (MediaRef, Int) async -> Data?)? = nil,
        statuses: (@Sendable () async -> AsyncStream<SearchIndexStatus>)? = nil,
        needsVerification: @escaping @MainActor () -> Bool = { false },
        onActivity: @escaping @MainActor () -> Void = {}
    ) {
        self.coordinator = coordinator
        self.roomName = roomName
        self.roomAvatar = roomAvatar
        self.thumbnailLoader = thumbnail
        self.statuses = statuses
        self.needsVerification = needsVerification
        self.onActivity = onActivity
    }

    /// Synchronously returns already-loaded thumbnail bytes so repeated room avatars and attachment cards paint on frame 0 without flashing.
    public func cachedThumbnail(for ref: MediaRef?) -> Data? {
        guard let ref else { return nil }
        return thumbnailMemory[ref]
    }

    /// Loads thumbnail bytes once and caches them in memory (`maxEntries = 256`).
    public func loadThumbnail(_ ref: MediaRef, pixelSize: Int) async -> Data? {
        if let hit = thumbnailMemory[ref] { return hit }
        guard let thumbnailLoader, let data = await thumbnailLoader(ref, pixelSize) else { return nil }
        if thumbnailMemory.count >= 256 { thumbnailMemory.removeAll(keepingCapacity: true) }
        thumbnailMemory[ref] = data
        return data
    }

    isolated deinit {
        dispatchTask?.cancel()
        for task in observations { task.cancel() }
    }

    public func start() async {
        guard observations.isEmpty else { return }
        let stream = await coordinator.snapshots()
        observations.append(SnippetPreparer.startTask(stream: stream) { [weak self] prepared in
            self?.apply(prepared)
        })
        guard let statuses else { return }
        observations.append(Task { [weak self] in
            for await status in await statuses() { self?.apply(status) }
        })
    }

    /// The keyboard's search button: runs remote verification immediately as well.
    public func submit() { search(now: true) }

    public func loadMore() async { await coordinator.loadMore() }

    public var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func queryChanged() {
        if trimmedQuery.isEmpty { filter = .all }
        search(now: false)
    }

    private func search(now: Bool) {
        onActivity()
        let nextQuery = SearchQuery(text: query, room: room, filter: filter)
        pendingDispatch = (nextQuery, (pendingDispatch?.now ?? false) || now)
        guard dispatchTask == nil else { return }
        // Single serial dispatcher: coalesces synchronous mutations and guarantees strict FIFO delivery to `SearchCoordinator`.
        dispatchTask = Task { [weak self, coordinator] in
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

    fileprivate struct PreparedHit: Sendable {
        let hit: MessageSearchHit
        let senderHighlights: [Range<Int>]
        let snippet: SearchTokeniser.Snippet
        let formattedTime: String
    }

    fileprivate struct PreparedSnapshot: Sendable {
        let snapshot: SearchCoordinator.Snapshot
        let preparedHits: [PreparedHit]?
    }

    private func apply(_ prepared: PreparedSnapshot) {
        let snapshot = prepared.snapshot
        isLoading = snapshot.isLoading
        hasMore = snapshot.hasMore
        errorMessage = snapshot.error.map { error in
            error == .storage(.unavailable) ? "Search isn't ready yet. Try again in a moment." : "Search couldn't complete."
        }
        guard let preparedHits = prepared.preparedHits else {
            // Keep existing rows steady on screen while the instant local lookup for the new keystroke completes (~1 ms).
            return
        }
        searchedQuery = snapshot.query.text
        rows = preparedHits.map { item in
            let hit = item.hit
            return ResultRow(
                id: hit.id, roomID: hit.roomID, eventID: hit.eventID, threadRoot: hit.threadRoot,
                roomName: roomName(hit.roomID), roomAvatar: roomAvatar(hit.roomID),
                sender: hit.senderName ?? Self.shortSender(hit.senderID), senderHighlights: item.senderHighlights,
                snippet: item.snippet.text, highlights: item.snippet.highlights,
                kind: hit.kind, attachment: hit.attachment,
                timestamp: hit.timestamp, formattedTime: item.formattedTime)
        }
    }

    /// Formats a raw `@alice:server.org` fallback cleanly as `alice` when no display name is cached.
    nonisolated static func shortSender(_ senderID: String) -> String {
        guard senderID.hasPrefix("@"), let colon = senderID.firstIndex(of: ":") else { return senderID }
        let localpart = senderID[senderID.index(after: senderID.startIndex)..<colon]
        return localpart.isEmpty ? senderID : String(localpart)
    }

    private var lastStatistics = SearchIndexStatistics()

    private func apply(_ status: SearchIndexStatus) {
        coverage = Self.coverage(status, canVerify: needsVerification())
        let changed = status.statistics != lastStatistics
        lastStatistics = status.statistics
        if changed, !trimmedQuery.isEmpty { Task { [coordinator] in await coordinator.refresh() } }
    }

    nonisolated static func coverage(_ status: SearchIndexStatus, canVerify: Bool, locale: Locale = .current) -> Coverage? {
        let missing = status.statistics.undecryptable
        guard status.totalRooms > 0, !status.isComplete || missing > 0 else { return nil }
        var parts: [String] = []
        if !status.isComplete {
            let chats = "\(status.completeRooms) of \(status.totalRooms) chats complete"
            if let date = status.searchedBackTo {
                parts.append("Searched back to \(date.formatted(.dateTime.month(.wide).year().locale(locale))) · \(chats)")
            } else {
                parts.append("Reading your chats · \(chats)")
            }
            if case .paused(let reason) = status.phase, let text = pauseText(reason) { parts.append(text) }
        }
        if missing > 0 {
            parts.append(missing == 1 ? "1 message can't be searched: its key isn't on this device." : "\(missing) messages can't be searched: their keys aren't on this device.")
        }
        return Coverage(text: parts.joined(separator: "\n"), undecryptable: missing, canVerify: missing > 0 && canVerify)
    }

    nonisolated static func pauseText(_ reason: SearchIndexPolicy.Pause) -> String? {
        switch reason {
        case .user: "Paused in Settings."
        case .lowPower: "Paused in Low Power Mode."
        case .hot: "Paused while your iPhone is warm."
        case .mobileData: "Paused on mobile data."
        case .offline: "Paused while offline."
        case .storageFull: "Paused: no space left."
        case .busy, .background: nil
        }
    }
}

private enum SnippetPreparer {
    struct CacheKey: Hashable {
        let id: String
        let body: String
        let termsKey: String
    }

    struct Cached {
        let senderHighlights: [Range<Int>]
        let snippet: SearchTokeniser.Snippet
        let formattedTime: String
    }

    static let maxCacheEntries = 512

    /// Runs snippet extraction, Unicode folding, highlight offset calculation and date formatting off the `@MainActor`,
    /// caching unchanged rows across pagination and progressive background updates.
    static func consume(
        _ stream: AsyncStream<SearchCoordinator.Snapshot>,
        deliver: @escaping @MainActor @Sendable (MessageSearchViewModel.PreparedSnapshot) -> Void
    ) async {
        var cache: [CacheKey: Cached] = [:]
        var lastSettledQuery = ""
        var lastSettledIDs: [String] = []
        for await snapshot in stream {
            if Task.isCancelled { return }
            let queryText = snapshot.query.text
            if queryText.isEmpty {
                lastSettledQuery = ""
                lastSettledIDs = []
                await deliver(.init(snapshot: snapshot, preparedHits: []))
                continue
            }
            let currentIDs = snapshot.hits.map(\.id)
            // Transient in-flight snapshot carrying the previous query's hits: skip re-tokenising stale hits on every keystroke.
            if snapshot.isLoading, queryText != lastSettledQuery, !lastSettledIDs.isEmpty, currentIDs == lastSettledIDs {
                await deliver(.init(snapshot: snapshot, preparedHits: nil))
                continue
            }
            let terms = SearchTokeniser.terms(queryText)
            let termsKey = SearchTokeniser.matchExpression(queryText) ?? ""
            if cache.count > maxCacheEntries { cache.removeAll(keepingCapacity: true) }
            let calendar = Calendar.current
            let now = Date.now
            let preparedHits: [MessageSearchViewModel.PreparedHit] = snapshot.hits.map { hit in
                let senderLabel = hit.senderName ?? MessageSearchViewModel.shortSender(hit.senderID)
                let key = CacheKey(id: hit.id, body: "\(senderLabel)\u{0}\(hit.body)", termsKey: termsKey)
                if let cached = cache[key] {
                    return .init(hit: hit, senderHighlights: cached.senderHighlights, snippet: cached.snippet, formattedTime: cached.formattedTime)
                }
                let senderHighlights = SearchTokeniser.preview(of: senderLabel, terms: terms, length: 80).highlights
                let snippet = SearchTokeniser.preview(of: hit.body, terms: terms)
                let time = MessageSearchViewModel.ResultRow.formatTime(hit.timestamp, now: now, calendar: calendar)
                cache[key] = Cached(senderHighlights: senderHighlights, snippet: snippet, formattedTime: time)
                return .init(hit: hit, senderHighlights: senderHighlights, snippet: snippet, formattedTime: time)
            }
            lastSettledQuery = queryText
            lastSettledIDs = currentIDs
            await deliver(.init(snapshot: snapshot, preparedHits: preparedHits))
        }
    }
    /// Launches `SnippetPreparer.consume` in a nonisolated context so `@MainActor` never runs tokenisation or date formatting.
    static func startTask(
        stream: AsyncStream<SearchCoordinator.Snapshot>,
        deliver: @escaping @MainActor @Sendable (MessageSearchViewModel.PreparedSnapshot) -> Void
    ) -> Task<Void, Never> {
        Task {
            await consume(stream, deliver: deliver)
        }
    }
}
