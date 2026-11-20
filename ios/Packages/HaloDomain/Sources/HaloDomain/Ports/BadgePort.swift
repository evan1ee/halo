import HaloFoundation

/// Shows the app badge and remembers which rooms need attention, so the notification extension can add to it when it
/// can't recompute everything (docs/matrix/UNREAD_STATE.md §8, PUSH_NOTIFICATIONS §3 step 7). Implemented by
/// `HaloPlatform`; faked in `HaloTestSupport`.
public protocol BadgePort: Sendable {
    /// Sets the badge to `attentionRooms.count` and stores the set.
    func update(attentionRooms: Set<RoomID>) async

    /// The set stored by the last `update` (or by the notification extension adding a room); empty if none. The app reads it
    /// at launch so an evaluation that hasn't seen every room yet can't erase a valid earlier result (V-RS-7 / D73).
    func lastAttention() async -> Set<RoomID>

    /// Forgets the stored set and clears the badge: only for an account change or sign-out, never for "nothing known yet".
    func reset() async
}
