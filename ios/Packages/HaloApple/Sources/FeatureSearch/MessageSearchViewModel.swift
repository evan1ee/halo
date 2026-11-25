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
        public let sender: String
        /// The part of the message around the match, and where it matches.
        public let snippet: String
        public let highlights: [Range<Int>]
        public let kind: SearchKind
        public let timestamp: Date
    }

    /// How far back the search reaches (FR-13); `nil` when every chat is read to its start and nothing is missing.
    public struct Coverage: Equatable, Sendable {
        public let text: String
        /// Messages that can't be decrypted on this device.
        public let undecryptable: Int
        public let canVerify: Bool
    }

    /// What is typed. Every change searches, after a pause in typing.
    public var query = "" { didSet { if query != oldValue { queryChanged() } } }
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
    private let statuses: (@Sendable () async -> AsyncStream<SearchIndexStatus>)?
    private let needsVerification: @MainActor () -> Bool
    private let onActivity: @MainActor () -> Void
    private var observations: [Task<Void, Never>] = []

    /// - Parameters:
    ///   - statuses: what the indexer is doing, for the coverage notice.
    ///   - needsVerification: verifying this device could make more messages readable.
    ///   - onActivity: the person is searching; indexing steps aside.
    public init(
        coordinator: SearchCoordinator, roomName: @escaping @MainActor (RoomID) -> String,
        statuses: (@Sendable () async -> AsyncStream<SearchIndexStatus>)? = nil, needsVerification: @escaping @MainActor () -> Bool = { false },
        onActivity: @escaping @MainActor () -> Void = {}
    ) {
        self.coordinator = coordinator
        self.roomName = roomName
        self.statuses = statuses
        self.needsVerification = needsVerification
        self.onActivity = onActivity
    }

    isolated deinit { for task in observations { task.cancel() } }

    public func start() async {
        guard observations.isEmpty else { return }
        let stream = await coordinator.snapshots()
        observations.append(Task { [weak self] in
            for await snapshot in stream { self?.apply(snapshot) }
        })
        guard let statuses else { return }
        observations.append(Task { [weak self] in
            for await status in await statuses() { self?.apply(status) }
        })
    }

    /// The keyboard's search button: without waiting.
    public func submit() { search(now: true) }

    public func loadMore() async { await coordinator.loadMore() }

    public var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func queryChanged() {
        if trimmedQuery.isEmpty { filter = .all }
        search(now: false)
    }

    private func search(now: Bool) {
        onActivity()
        // Reads what is typed when it runs: whichever of two calls comes last, the newest text wins.
        Task { [coordinator] in await coordinator.search(SearchQuery(text: self.query, filter: self.filter), now: now) }
    }

    private func apply(_ snapshot: SearchCoordinator.Snapshot) {
        searchedQuery = snapshot.query.text
        isLoading = snapshot.isLoading
        hasMore = snapshot.hasMore
        errorMessage = snapshot.error.map { error in
            error == .storage(.unavailable) ? "Search isn't ready yet. Try again in a moment." : "Search couldn't complete."
        }
        let query = snapshot.query.text
        rows = snapshot.hits.map { hit in
            let snippet = SearchTokeniser.snippet(of: hit.body, query: query)
            return ResultRow(
                id: hit.id, roomID: hit.roomID, eventID: hit.eventID, threadRoot: hit.threadRoot, roomName: roomName(hit.roomID),
                sender: hit.senderName ?? hit.senderID, snippet: snippet,
                highlights: SearchTokeniser.highlights(in: snippet, query: query).map { range in
                    snippet.distance(from: snippet.startIndex, to: range.lowerBound)..<snippet.distance(from: snippet.startIndex, to: range.upperBound)
                },
                kind: hit.kind, timestamp: hit.timestamp)
        }
    }

    private var indexedMessages = 0

    private func apply(_ status: SearchIndexStatus) {
        coverage = Self.coverage(status, canVerify: needsVerification())
        let grown = status.statistics.messages > indexedMessages
        indexedMessages = status.statistics.messages
        if grown, !trimmedQuery.isEmpty { Task { [coordinator] in await coordinator.refresh() } }
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
