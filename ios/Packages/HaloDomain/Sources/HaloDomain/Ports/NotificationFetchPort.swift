import Foundation
import HaloFoundation

/// What to show for one push (docs/matrix/PUSH_NOTIFICATIONS.md §3). Text only; the sender's avatar and
/// communication-notification details come later.
public struct NotificationDisplay: Sendable, Equatable {
    public let title: String
    public let body: String
    /// When the event was sent, and whether it mentions the user; both feed the notification record.
    public let timestamp: Date?
    public let isMention: Bool

    public init(title: String, body: String, timestamp: Date? = nil, isMention: Bool = false) {
        self.title = title
        self.body = body
        self.timestamp = timestamp
        self.isMention = isMention
    }
}

public enum NotificationFetchResult: Sendable, Equatable {
    case display(NotificationDisplay)
    /// The event is encrypted and this device can't read it (yet): "Encrypted message" in `roomName`.
    case encrypted(roomName: String?)
    /// The user's push rules or the event's state say nothing should be shown (filtered out, redacted).
    case suppressed
}

/// Fetches and decrypts the event a push points at, through the SDK, in the notification extension
/// (PUSH_NOTIFICATIONS §3 step 2). Implemented by `HaloMatrixAdapter`. Throws `.notFound` when the event can't be
/// found, `.unauthorized` without a session.
public protocol NotificationFetchPort: Sendable {
    func fetch(room: RoomID, event: EventID) async throws(HaloError) -> NotificationFetchResult
}
