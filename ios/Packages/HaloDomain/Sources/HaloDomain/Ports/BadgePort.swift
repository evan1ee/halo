import HaloFoundation

/// Shows the app badge and remembers per-room unread badge counts, so the notification extension can recompute the
/// badge when it can't evaluate every room (docs/matrix/UNREAD_STATE.md §8, PUSH_NOTIFICATIONS §3 step 7, D82).
/// Implemented by `HaloPlatform`; faked in `HaloTestSupport`.
public protocol BadgePort: Sendable {
    /// Sets the badge to `attentionCounts.values.reduce(0, +)` (total unread messages across rooms needing attention,
    /// D82) and stores the per-room counts.
    func update(attentionCounts: [RoomID: Int]) async

    /// The per-room counts stored by the last `update`; empty if none. The app reads them at launch so an evaluation
    /// that hasn't seen every room yet can't erase a valid earlier result (V-RS-7 / D73).
    func lastAttention() async -> [RoomID: Int]

    /// Forgets the stored counts and clears the badge: only for an account change or sign-out, never for "nothing known yet".
    func reset() async
}
