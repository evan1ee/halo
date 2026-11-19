import HaloFoundation

/// Outbound read state (docs/matrix/PORTS_CONTRACT.md §2, docs/matrix/READ_RECEIPTS.md §1). Implemented by
/// `HaloMatrixAdapter`; faked in `HaloTestSupport`. Receipts are unthreaded (D17).
public protocol ReadMarkerPort: Sendable {
    /// Sends a read receipt for `event`: `m.read`, or `m.read.private` when `isPrivate` (D7).
    func sendReceipt(room: RoomID, event: EventID, isPrivate: Bool) async throws(HaloError)

    /// Moves the fully-read marker to `event`.
    func setFullyRead(room: RoomID, event: EventID) async throws(HaloError)
}
