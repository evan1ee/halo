import Foundation
import HaloFoundation

/// One message found by search.
public struct MessageSearchHit: Sendable, Equatable, Identifiable {
    public let roomID: RoomID
    public let eventID: EventID
    public let threadRoot: EventID?
    public let senderID: String
    public let senderName: String?
    public let body: String
    public let timestamp: Date
    public let kind: SearchKind
    public let attachment: SearchAttachment?

    public var id: String { "\(roomID.rawValue)::\(eventID.rawValue)" }

    public init(
        roomID: RoomID, eventID: EventID, threadRoot: EventID? = nil, senderID: String, senderName: String?,
        body: String, timestamp: Date, kind: SearchKind = .message, attachment: SearchAttachment? = nil
    ) {
        self.roomID = roomID
        self.eventID = eventID
        self.threadRoot = threadRoot
        self.senderID = senderID
        self.senderName = senderName
        self.body = body
        self.timestamp = timestamp
        self.kind = kind
        self.attachment = attachment
    }
}

/// One page of results, newest first.
public struct SearchPage: Sendable, Equatable {
    public let hits: [MessageSearchHit]
    /// Where the next page begins; `nil` at the end.
    public let next: SearchCursor?

    public init(hits: [MessageSearchHit], next: SearchCursor?) {
        self.hits = hits
        self.next = next
    }
}

/// Searches the messages of all rooms on this device (docs/features/MESSAGE_SEARCH.md). A call answers exactly the query it was given,
/// so a late answer can't be taken for another query's. Cancelling the task cancels the search (`.cancelled`).
public protocol SearchPort: Sendable {
    /// `query.text` without a searchable word gives an empty page. Throws `.storage(.unavailable)` while the index can't be read.
    func search(_ query: SearchQuery, after cursor: SearchCursor?) async throws(HaloError) -> SearchPage

    /// Immediate results from the local on-device index without waiting on remote server verification.
    func searchLocal(_ query: SearchQuery, after cursor: SearchCursor?) async throws(HaloError) -> SearchPage

    /// Re-checks `hits` against the remote server in the background when due, updating the index and returning hits whose state changed (`.edited` or `.gone`), keyed by `MessageSearchHit.id`.
    func recheck(_ hits: [MessageSearchHit]) async throws(HaloError) -> [String: SearchRecheck]
}

extension SearchPort {
    public func searchLocal(_ query: SearchQuery, after cursor: SearchCursor?) async throws(HaloError) -> SearchPage {
        try await search(query, after: cursor)
    }

    public func recheck(_ hits: [MessageSearchHit]) async throws(HaloError) -> [String: SearchRecheck] {
        [:]
    }
}

/// Halo's own full-text index of one account (D123, ADR-0024). Implemented by `HaloPersistence`; derived data, never truth.
public protocol LocalSearchIndexPort: Sendable {
    /// Applies writes in order; each is all or nothing, except that a removed room goes in steps. While the index can't be opened (locked phone) they are kept encrypted and applied later.
    func apply(_ operations: [SearchIndexOperation]) async throws(HaloError)

    /// Rows matching `match` (from `SearchTokeniser.matchExpression`), newest first, at most `limit`, after `cursor`, without `excluding` senders.
    func hits(match: String, room: RoomID?, kinds: Set<SearchKind>, excluding: Set<UserID>, after cursor: SearchCursor?, limit: Int) async throws(HaloError) -> [SearchIndexHit]

    /// The SDK's answer about shown rows.
    func record(_ rechecks: [(room: RoomID, event: EventID, result: SearchRecheck)]) async throws(HaloError)

    /// What to read next among `rooms` (most recent first): rooms to check, gaps, due keys, then history. At most `limit`.
    func nextWork(rooms: [RoomID], limit: Int) async throws(HaloError) -> [SearchHistoryWork]

    /// Which of `events` the index knows (searchable, without a key, or nothing to search).
    func known(_ events: [EventID], in room: RoomID) async throws(HaloError) -> Set<EventID>

    func coverage() async throws(HaloError) -> [RoomID: RoomSearchCoverage]
    func statistics() async throws(HaloError) -> SearchIndexStatistics
    /// Rooms with anything in the index.
    func indexedRooms() async throws(HaloError) -> Set<RoomID>
    /// Makes every message without a key due now (a key backup was connected).
    func retryUndecryptableNow() async throws(HaloError)
    /// Empties the index; reading starts again.
    func clear() async throws(HaloError)
}

/// Reads decrypted messages for the index (ADR-0024). Implemented by `HaloMatrixAdapter`.
public protocol MessageIndexSourcePort: Sendable {
    /// What each sync response brings, from now on. One subscriber.
    func batches() -> AsyncStream<SearchLiveBatch>
    /// Rooms to listen to (joined rooms, most recent first). The list may be incomplete: rooms already followed stay followed until left.
    func follow(_ rooms: [RoomID]) async
    /// The joined rooms this device knows; `nil` when that can't be said. Unlike a room list still loading, never only a part of them.
    func joinedRooms() async -> Set<RoomID>?
    /// Listens to every joined room known on this device, before the room list is there.
    func followKnownRooms() async
    /// The room's newest event, from the server; `nil` when the room has none this user may see.
    func newestEvent(in room: RoomID) async throws(HaloError) -> EventID?
    /// The messages among the room's newest `limit` events, newest first; deleted ones, edits and answers to polls left out.
    func recentMessages(in room: RoomID, limit: Int) async throws(HaloError) -> [SearchRecentMessage]
    /// `event` and up to `pages` pages of what came before it, decrypted as far as keys allow.
    func history(in room: RoomID, from event: EventID, pages: Int) async throws(HaloError) -> SearchHistorySlice
    /// The message as the SDK or the server has it now.
    func recheck(_ event: EventID, in room: RoomID) async throws(HaloError) -> SearchRecheck
    /// Lets go of what `history` loaded.
    func endBatch() async
    /// Stops listening and lets go of everything (sign-out).
    func stop() async
}
