import Foundation
import HaloFoundation

/// Room details and management (docs/features/ROOM_MANAGEMENT.md §8). Implemented by `HaloMatrixAdapter`; faked in `HaloTestSupport`.
public protocol RoomPort: Sendable {
    /// Name, topic, encryption, member count and the user's notification mode. Throws `.notFound` for an unknown room.
    func details(_ room: RoomID) async throws(HaloError) -> RoomDetails

    /// Joined and invited members, administrators first, then by name (FR-2). Loads the first `limit` only.
    func members(_ room: RoomID, limit: Int) async throws(HaloError) -> [RoomMemberInfo]

    /// Banned members of `room`, alphabetically by title (FR-10, M20-12). Loads the first `limit` only.
    func bannedMembers(_ room: RoomID, limit: Int) async throws(HaloError) -> [RoomMemberInfo]

    /// Removes (kicks) a joined member or withdraws an invitation (FR-10, M20-12). Throws `.forbidden` when power levels refuse.
    func removeMember(_ user: UserID, from room: RoomID, reason: String?) async throws(HaloError)

    /// Bans a user from `room` (FR-10, M20-12). Throws `.forbidden` when power levels refuse.
    func banMember(_ user: UserID, from room: RoomID, reason: String?) async throws(HaloError)

    /// Unbans a previously banned user in `room` (FR-10, M20-12). Throws `.forbidden` when power levels refuse.
    func unbanMember(_ user: UserID, from room: RoomID, reason: String?) async throws(HaloError)

    /// Stores the user's own mode for the room as a push rule, so every device follows it (FR-3).
    func setNotificationMode(_ mode: RoomNotificationChoice, in room: RoomID) async throws(HaloError)

    /// Sets the room name and topic; an empty string clears the topic (FR-7). Throws `.forbidden` without the power level.
    func setDetails(name: String, topic: String, in room: RoomID) async throws(HaloError)

    /// Uploads `data` (an image already shrunk) as the room's avatar (FR-7). Throws `.forbidden` without the power level.
    func setAvatar(mimeType: String, data: Data, in room: RoomID) async throws(HaloError)

    /// Removes the room's avatar.
    func removeAvatar(in room: RoomID) async throws(HaloError)

    /// Invites `users` to the room (FR-5). Throws `.forbidden` without the power level.
    func invite(_ users: [UserID], to room: RoomID) async throws(HaloError)

    /// Accepts an invitation: joins the room (FR-6). Throws `.notFound` when the invitation was withdrawn.
    func acceptInvite(_ room: RoomID) async throws(HaloError)

    /// The room's name, topic and size, to show with an invitation. Throws `.notFound` when the room can't be previewed.
    func invitePreview(_ room: RoomID) async throws(HaloError) -> RoomInvitePreview

    /// Declines an invitation: leaves the invited room (FR-6).
    func declineInvite(_ room: RoomID) async throws(HaloError)

    /// Adds or removes the room from the favourites (`m.favourite` tag; ROOM_LIST FR-6).
    func setFavourite(_ favourite: Bool, in room: RoomID) async throws(HaloError)

    /// Leaves the room (FR-4).
    func leave(_ room: RoomID) async throws(HaloError)

    /// Forgets a left or banned room on the homeserver so it never lingers as a stuck row (M20-8).
    func forget(_ room: RoomID) async throws(HaloError)

    /// Previews a room by room ID (`!…`) or alias (`#…`), reporting membership and join rule (knock, invite-only, banned, public; M20-8).
    func previewRoom(address: String) async throws(HaloError) -> RoomLifecyclePreview

    /// Sends a knock request to join a knock-enabled room (`address` is a room ID or alias; M20-8).
    func knock(address: String, reason: String?) async throws(HaloError) -> RoomID

    /// Known rooms whose membership is `.knocked`, `.left`, or `.banned` (non-spaces), so the user can cancel, rejoin, or forget them (M20-8).
    func inactiveRooms() async -> [RoomSummary]

    /// Recent media items (photos, videos, audio, files) in `room`, newest first (M9 Gallery + Export).
    func mediaGallery(in room: RoomID, limit: Int) async throws(HaloError) -> [RoomMediaItem]

    /// Opens a paged media gallery session for `room` (M19-5) so scrolling loads older pages without re-fetching from the start.
    func openMediaGallery(in room: RoomID) async throws(HaloError) -> any RoomMediaGallerySession

    /// Recent messages in `room` in chronological order (oldest first) for on-demand encrypted export (D32, R-P2-EXPORT).
    func exportMessages(in room: RoomID, limit: Int) async throws(HaloError) -> [RoomExportMessage]
}

/// A live, paged reader for one room's media gallery (M19-5).
public protocol RoomMediaGallerySession: Sendable {
    /// Returns the next page of up to `limit` media items (newest first within the page, older than previous pages).
    func nextPage(limit: Int) async throws(HaloError) -> MediaGalleryPage
    /// Releases the underlying timeline and subscriptions.
    func close() async
}

private actor SinglePageMediaGallerySession: RoomMediaGallerySession {
    private let port: any RoomPort
    private let room: RoomID
    private var loaded = false

    init(port: any RoomPort, room: RoomID) {
        self.port = port
        self.room = room
    }

    func nextPage(limit: Int) async throws(HaloError) -> MediaGalleryPage {
        guard !loaded else { return MediaGalleryPage(items: [], hasMore: false) }
        loaded = true
        let items = try await port.mediaGallery(in: room, limit: limit)
        return MediaGalleryPage(items: items, hasMore: false)
    }

    func close() async {}
}

extension RoomPort {
    public func bannedMembers(_ room: RoomID, limit: Int) async throws(HaloError) -> [RoomMemberInfo] { [] }
    public func removeMember(_ user: UserID, from room: RoomID, reason: String?) async throws(HaloError) {
        throw .unsupported("KICK")
    }
    public func banMember(_ user: UserID, from room: RoomID, reason: String?) async throws(HaloError) {
        throw .unsupported("BAN")
    }
    public func unbanMember(_ user: UserID, from room: RoomID, reason: String?) async throws(HaloError) {
        throw .unsupported("UNBAN")
    }
    public func forget(_ room: RoomID) async throws(HaloError) {}
    public func previewRoom(address: String) async throws(HaloError) -> RoomLifecyclePreview {
        RoomLifecyclePreview(roomID: try? RoomID(address), address: address, joinAccess: .unknown)
    }
    public func knock(address: String, reason: String?) async throws(HaloError) -> RoomID {
        throw .unsupported("KNOCK")
    }
    public func inactiveRooms() async -> [RoomSummary] { [] }
    public func mediaGallery(in room: RoomID, limit: Int) async throws(HaloError) -> [RoomMediaItem] { [] }
    public func openMediaGallery(in room: RoomID) async throws(HaloError) -> any RoomMediaGallerySession {
        SinglePageMediaGallerySession(port: self, room: room)
    }
    public func exportMessages(in room: RoomID, limit: Int) async throws(HaloError) -> [RoomExportMessage] { [] }
}
