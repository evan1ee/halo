import HaloFoundation

/// Shows the app badge and remembers which rooms need attention, so the notification extension can add to it when it
/// can't recompute everything (docs/matrix/UNREAD_STATE.md §8, PUSH_NOTIFICATIONS §3 step 7). Implemented by
/// `HaloPlatform`; faked in `HaloTestSupport`.
public protocol BadgePort: Sendable {
    /// Sets the badge to `attentionRooms.count` and stores the set.
    func update(attentionRooms: Set<RoomID>) async
}
