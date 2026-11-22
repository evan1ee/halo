import Foundation
import HaloFoundation

/// The read position the user reached in a room on this device (docs/matrix/UNREAD_STATE.md §2 "local read intent").
public struct ReadIntent: Sendable, Equatable {
    public let room: RoomID
    public let event: EventID
    /// `origin_server_ts` of `event`.
    public let timestamp: Date
    /// The server acknowledged the receipt; until then the intent is a durable outbox entry.
    public let isSent: Bool
    /// When the intent was created; sent intents expire 7 days later (READ_RECEIPTS §1).
    public let createdAt: Date
    /// How many sends of this intent failed, and the stable code of the last failure (`HaloError.code`). Bookkeeping
    /// for diagnosis; both reset when a newer event replaces the intent.
    public let attempts: Int
    public let lastError: String?
    /// Monotonic per-room order key assigned when timeline order proves an event is newer than the previous intent,
    /// allowing equal or clock-skewed timestamps to advance cleanly (R-06, ADR-0020).
    public let sequence: Int64

    public init(
        room: RoomID, event: EventID, timestamp: Date, isSent: Bool = false, createdAt: Date,
        attempts: Int = 0, lastError: String? = nil, sequence: Int64 = 0
    ) {
        self.attempts = attempts
        self.lastError = lastError
        self.sequence = sequence
        self.room = room
        self.event = event
        self.timestamp = timestamp
        self.isSent = isSent
        self.createdAt = createdAt
    }
}

/// Durable storage of read intents, one per room, moving only forward (docs/data/PERSISTENCE.md §4). Implemented by
/// `HaloPersistence`; faked in `HaloTestSupport`.
public protocol ReadIntentPort: Sendable {
    /// Every stored intent.
    func all() async throws(HaloError) -> [ReadIntent]

    /// Stores `intent` unless the room already has one with a newer timestamp. For the same event, a sent intent
    /// never goes back to unsent.
    func save(_ intent: ReadIntent) async throws(HaloError)

    /// Counts a failed send of the room's intent for `event` and keeps `code`. Ignored when the room's intent is for
    /// another event or already sent.
    func recordFailure(room: RoomID, event: EventID, code: String) async throws(HaloError)

    /// Deletes sent intents created before `date` (unsent intents never expire).
    func removeSent(createdBefore date: Date) async throws(HaloError)
}
