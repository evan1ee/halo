import Foundation
import HaloFoundation

/// One notifying event the notification extension fetched from the homeserver (never taken from a push payload, D65).
/// It counts towards attention until sync delivers the event or the user reads the room (rule E4, UNREAD_STATE §2/§8).
public struct NotificationRecord: Sendable, Equatable, Codable {
    public enum Source: String, Sendable, Equatable, Codable {
        case nse, app
    }

    public let roomID: RoomID
    public let eventID: EventID
    /// The event's `origin_server_ts` (not the extension's wall clock, R-02).
    public let timestamp: Date
    public let isMention: Bool
    /// When this device recorded the delivery (used for 7-day retention).
    public let deliveredAt: Date
    public let source: Source

    public init(
        roomID: RoomID, eventID: EventID, timestamp: Date, isMention: Bool,
        deliveredAt: Date? = nil, source: Source = .nse
    ) {
        self.roomID = roomID
        self.eventID = eventID
        self.timestamp = timestamp
        self.isMention = isMention
        self.deliveredAt = deliveredAt ?? timestamp
        self.source = source
    }
}

/// The notification records, shared by the app and the extension (docs/matrix/UNREAD_STATE.md §8, DATA_MODELS §3:
/// `notification_record`, primary key = `(account, event_id)`, which also de-duplicates repeated pushes, AC-U7).
/// Implemented by `HaloPersistence` over GRDB.
public protocol NotificationRecordPort: Sendable {
    func all() -> [NotificationRecord]
    /// Like `all()`, but `nil` when the store can't be read right now: "unknown", not "none".
    func load() -> [NotificationRecord]?
    /// Adds the record; returns `false` if that event already had one (a duplicate push).
    @discardableResult func add(_ record: NotificationRecord) -> Bool
    /// Removes all records for `room`.
    func clear(room: RoomID)
    /// Removes all records for any of `rooms` (left, hidden, or ignored-inviter rooms, R-03).
    func clear(rooms: Set<RoomID>)
    /// Removes records whose `eventID` is in `events` (superseded by sync or covered by a read position, R-02).
    func remove(events: Set<EventID>)
    /// Removes all records for the current account (sign-out or account change, R-03).
    func clearAll()
    /// Fires after any process changes the records (the extension runs in another process).
    func changes() -> AsyncStream<Void>
}

public extension NotificationRecordPort {
    func load() -> [NotificationRecord]? { all() }
}
