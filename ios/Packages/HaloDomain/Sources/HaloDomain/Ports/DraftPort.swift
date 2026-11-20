import HaloFoundation

/// Durable storage of the unsent message per room (docs/features/MESSAGING.md FR-5). Implemented by `HaloPersistence`;
/// faked in `HaloTestSupport`. A draft is local only; it is never synchronised.
public protocol DraftPort: Sendable {
    /// The stored draft of `room`, or `nil` if there is none.
    func draft(for room: RoomID) async throws(HaloError) -> String?

    /// Stores `text` as the draft of `room`; blank text deletes the draft.
    func save(_ text: String, for room: RoomID) async throws(HaloError)
}
