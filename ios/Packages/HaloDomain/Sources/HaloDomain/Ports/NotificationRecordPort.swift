import Foundation
import HaloFoundation

/// One notifying event the notification extension fetched from the homeserver (never taken from a push payload, D65).
/// It counts towards attention until the user reads the room here (rule E4, UNREAD_STATE §2/§8). The room list can't
/// show it as unread by itself: Synapse's native sliding sync serves no notification counts (V-RS-7).
public struct NotificationRecord: Sendable, Equatable, Codable {
    public let roomID: RoomID
    public let eventID: EventID
    public let timestamp: Date
    public let isMention: Bool

    public init(roomID: RoomID, eventID: EventID, timestamp: Date, isMention: Bool) {
        self.roomID = roomID
        self.eventID = eventID
        self.timestamp = timestamp
        self.isMention = isMention
    }
}

/// The notification records, shared by the app and the extension (docs/matrix/UNREAD_STATE.md §8: `notification_record`,
/// primary key = event ID, which also de-duplicates repeated pushes, AC-U7). Implemented by `HaloPlatform`.
public protocol NotificationRecordPort: Sendable {
    func all() -> [NotificationRecord]
    /// Adds the record; returns `false` if that event already had one (a duplicate push).
    @discardableResult func add(_ record: NotificationRecord) -> Bool
    /// The user read `room` here: its records no longer count.
    func clear(room: RoomID)
    /// Fires after any process changes the records (the extension runs in another process).
    func changes() -> AsyncStream<Void>
}
