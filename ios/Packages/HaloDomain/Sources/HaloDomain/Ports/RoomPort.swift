import HaloFoundation

/// Room details and management (docs/features/ROOM_MANAGEMENT.md §8). Implemented by `HaloMatrixAdapter`; faked in `HaloTestSupport`.
public protocol RoomPort: Sendable {
    /// Name, topic, encryption, member count and the user's notification mode. Throws `.notFound` for an unknown room.
    func details(_ room: RoomID) async throws(HaloError) -> RoomDetails

    /// Joined and invited members, administrators first, then by name (FR-2). Loads the first `limit` only.
    func members(_ room: RoomID, limit: Int) async throws(HaloError) -> [RoomMemberInfo]

    /// Stores the user's own mode for the room as a push rule, so every device follows it (FR-3).
    func setNotificationMode(_ mode: RoomNotificationChoice, in room: RoomID) async throws(HaloError)

    /// Sets the room name and topic; an empty string clears the topic (FR-7). Throws `.forbidden` without the power level.
    func setDetails(name: String, topic: String, in room: RoomID) async throws(HaloError)

    /// Invites `users` to the room (FR-5). Throws `.forbidden` without the power level.
    func invite(_ users: [UserID], to room: RoomID) async throws(HaloError)

    /// Accepts an invitation: joins the room (FR-6). Throws `.notFound` when the invitation was withdrawn.
    func acceptInvite(_ room: RoomID) async throws(HaloError)

    /// Declines an invitation: leaves the invited room (FR-6).
    func declineInvite(_ room: RoomID) async throws(HaloError)

    /// Leaves the room (FR-4).
    func leave(_ room: RoomID) async throws(HaloError)
}
