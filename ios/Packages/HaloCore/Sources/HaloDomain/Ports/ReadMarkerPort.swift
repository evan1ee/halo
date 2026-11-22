import HaloFoundation

/// Outbound read state (docs/matrix/PORTS_CONTRACT.md §2, docs/matrix/READ_RECEIPTS.md §1). Implemented by
/// `HaloMatrixAdapter`; faked in `HaloTestSupport`. Receipts are unthreaded (D17).
public protocol ReadMarkerPort: Sendable {
    /// Sends a read receipt for `event`: `m.read`, or `m.read.private` when `isPrivate` (D7).
    func sendReceipt(room: RoomID, event: EventID, isPrivate: Bool) async throws(HaloError)

    /// Moves the fully-read marker to `event`.
    func setFullyRead(room: RoomID, event: EventID) async throws(HaloError)

    /// Marks everything in `room` read (room-list "Mark as read"): sends the receipt and the fully-read marker for the
    /// room's latest event and returns that event, or `nil` when the room has none. The room list has no event ID of
    /// its own for it (F-FFI-15), so the adapter resolves it.
    func markRoomRead(room: RoomID, isPrivate: Bool) async throws(HaloError) -> EventID?

    /// Sets or clears the "marked unread" flag (`m.marked_unread`).
    func setMarkedUnread(room: RoomID, _ value: Bool) async throws(HaloError)
}
