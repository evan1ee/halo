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
}
