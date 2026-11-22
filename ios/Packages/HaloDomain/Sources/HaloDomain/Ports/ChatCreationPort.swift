import HaloFoundation

/// A user found by the directory search (ROOM_MANAGEMENT FR-5).
public struct UserSummary: Sendable, Equatable, Identifiable {
    public let id: UserID
    public let displayName: String?

    public init(id: UserID, displayName: String?) {
        self.id = id
        self.displayName = displayName
    }

    /// The name to show: the display name, else the user ID.
    public var title: String { displayName?.isEmpty == false ? displayName! : id.rawValue }
}

/// Starting conversations (ROOM_MANAGEMENT FR-5). Implemented by `HaloMatrixAdapter`; faked in `HaloTestSupport`.
public protocol ChatCreationPort: Sendable {
    /// Users matching `term` in the server's user directory. An empty term gives no results.
    func searchUsers(_ term: String, limit: Int) async throws(HaloError) -> [UserSummary]

    /// The existing direct chat with `user`, or a new encrypted one with an invitation. Never creates a second chat with the same user.
    func startDirectChat(with user: UserID) async throws(HaloError) -> RoomID

    /// A new private, encrypted room that invites `invite`.
    func createRoom(name: String, invite: [UserID]) async throws(HaloError) -> RoomID

    /// Returns the user's private encrypted Saved Messages room (stored in `one.mbm.halo.saved_room` account data),
    /// creating it once if none exists or if the previously recorded room was left (M8 Search + Saved).
    func openOrCreateSavedRoom() async throws(HaloError) -> RoomID

    /// Joins an existing room by Matrix room alias (`#room:server`) or room ID (`!room:server`) (ROOM_MANAGEMENT FR-5).
    func joinRoom(_ idOrAlias: String) async throws(HaloError) -> RoomID
}

extension ChatCreationPort {
    public func openOrCreateSavedRoom() async throws(HaloError) -> RoomID {
        try await createRoom(name: "Saved Messages", invite: [])
    }

    public func joinRoom(_ idOrAlias: String) async throws(HaloError) -> RoomID {
        throw .unsupported("JOIN_ROOM")
    }
}
