import Foundation
import HaloFoundation

/// One message hit returned by `SearchPort` (M8 Search + Saved, V-SEARCH-1).
public struct MessageSearchHit: Sendable, Equatable, Identifiable {
    public let roomID: RoomID
    public let eventID: EventID
    public let senderID: String
    public let senderName: String?
    public let body: String
    public let timestamp: Date

    public var id: String { "\(roomID.rawValue)::\(eventID.rawValue)" }

    public init(
        roomID: RoomID,
        eventID: EventID,
        senderID: String,
        senderName: String?,
        body: String,
        timestamp: Date
    ) {
        self.roomID = roomID
        self.eventID = eventID
        self.senderID = senderID
        self.senderName = senderName
        self.body = body
        self.timestamp = timestamp
    }
}

/// Snapshot of an active search session.
public struct SearchSnapshot: Sendable, Equatable {
    public let hits: [MessageSearchHit]
    public let isLoading: Bool
    public let hasMore: Bool

    public init(hits: [MessageSearchHit], isLoading: Bool, hasMore: Bool) {
        self.hits = hits
        self.isLoading = isLoading
        self.hasMore = hasMore
    }

    public static let empty = SearchSnapshot(hits: [], isLoading: false, hasMore: false)
}

/// Searches messages across the user's rooms (M8 Search + Saved, V-SEARCH-1).
/// Implemented by `MatrixSearchPort` over the SDK's `SearchService` in `HaloMatrixAdapter`; faked in `HaloTestSupport`.
public protocol SearchPort: Sendable {
    /// Emits the current search results snapshot and every subsequent update while subscribed.
    func snapshots() -> AsyncStream<SearchSnapshot>

    /// Sets or updates the search query, clearing previous hits and loading the first page.
    func setQuery(_ query: String) async throws(HaloError)

    /// Loads the next page of results when `hasMore` is true.
    func loadMore() async throws(HaloError)
}
