import Foundation
import HaloFoundation

/// One authoritative evaluation by the app: what the badge, the widgets and the extension's baseline become.
public struct BadgeSnapshot: Sendable, Equatable {
    /// Unread messages per room needing attention (D82).
    public let attentionCounts: [RoomID: Int]
    /// When the app read its inputs. Notification records delivered later aren't in `attentionCounts` yet.
    public let evaluatedAt: Date
    /// The newest event sync has delivered per room. A push for an event up to here is already in `attentionCounts`
    /// (or was read), so the extension must not count it again.
    public let syncedThrough: [RoomID: Date]

    public init(attentionCounts: [RoomID: Int], evaluatedAt: Date, syncedThrough: [RoomID: Date] = [:]) {
        self.attentionCounts = attentionCounts
        self.evaluatedAt = evaluatedAt
        self.syncedThrough = syncedThrough
    }

    public var total: Int { BadgeCalculator.total(attentionCounts) }
}

/// What the notification extension starts from: the app's last evaluation and what is shown right now (that evaluation
/// plus the pushes since). `counts` and `displayed` differ only between app runs.
public struct AttentionBaseline: Sendable, Equatable {
    public let counts: [RoomID: Int]
    public let displayed: [RoomID: Int]
    public let evaluatedAt: Date?
    public let syncedThrough: [RoomID: Date]

    public init(
        counts: [RoomID: Int], displayed: [RoomID: Int]? = nil, evaluatedAt: Date? = nil, syncedThrough: [RoomID: Date] = [:]
    ) {
        self.counts = counts
        self.displayed = displayed ?? counts
        self.evaluatedAt = evaluatedAt
        self.syncedThrough = syncedThrough
    }
}

/// Shows the app badge and remembers per-room unread badge counts, so the notification extension can recompute the
/// badge when it can't evaluate every room (docs/matrix/UNREAD_STATE.md §8, PUSH_NOTIFICATIONS §3 step 7, D82).
/// Implemented by `HaloPlatform`; faked in `HaloTestSupport`. `ReadStateCoordinator` calls it one write at a time.
public protocol BadgePort: Sendable {
    /// Sets the badge to the snapshot's total (unread messages across rooms needing attention, D82) and stores it for
    /// the widgets and the extension.
    func update(_ snapshot: BadgeSnapshot) async

    /// The per-room counts shown now (the last `update` plus what the extension added since); empty if none. The app
    /// reads them at launch so an evaluation made before the first sync can't erase a valid result (V-RS-7 / D73).
    func lastAttention() async -> [RoomID: Int]

    /// Forgets the stored counts and clears the badge: only for an account change or sign-out, never for "nothing known yet".
    func reset() async
}
