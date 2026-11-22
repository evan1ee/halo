import Foundation
import HaloDomain
import HaloFoundation
import Synchronization

/// In-memory `RoomPort`: one room's details, a member list, and records of what was changed.
public final class FakeRoomPort: RoomPort {
    private struct State {
        var details: RoomDetails
        var members: [RoomMemberInfo]
        var avatars: [Data] = []
        var avatarRemovals = 0
        var error: HaloError?
        var modes: [RoomNotificationChoice] = []
        var left: [RoomID] = []
        var edits: [(name: String, topic: String)] = []
        var invites: [[UserID]] = []
        var favourites: [(room: RoomID, on: Bool)] = []
        var accepted: [RoomID] = []
        var declined: [RoomID] = []
        var gallery: [RoomMediaItem] = []
    }
    private let state: Mutex<State>

    public init(details: RoomDetails, members: [RoomMemberInfo] = [], gallery: [RoomMediaItem] = []) {
        state = Mutex(State(details: details, members: members, gallery: gallery))
    }

    /// Makes every following call throw (nil: stop failing).
    public func fail(with error: HaloError?) { state.withLock { $0.error = error } }
    public func setDetails(_ details: RoomDetails) { state.withLock { $0.details = details } }
    public var modeChanges: [RoomNotificationChoice] { state.withLock { $0.modes } }
    public var leftRooms: [RoomID] { state.withLock { $0.left } }

    public func details(_ room: RoomID) async throws(HaloError) -> RoomDetails {
        let (details, error) = state.withLock { ($0.details, $0.error) }
        if let error { throw error }
        guard details.id == room else { throw .notFound }
        return details
    }

    public func members(_ room: RoomID, limit: Int) async throws(HaloError) -> [RoomMemberInfo] {
        let (members, error) = state.withLock { ($0.members, $0.error) }
        if let error { throw error }
        return Array(members.prefix(limit))
    }

    public func setNotificationMode(_ mode: RoomNotificationChoice, in room: RoomID) async throws(HaloError) {
        if let error = state.withLock({ $0.error }) { throw error }
        state.withLock {
            $0.modes.append(mode)
            $0.details = $0.details.with(notificationMode: mode)
        }
    }

    public var detailEdits: [(name: String, topic: String)] { state.withLock { $0.edits } }
    public var sentInvites: [[UserID]] { state.withLock { $0.invites } }

    public var avatarUploads: [Data] { state.withLock { $0.avatars } }
    public var avatarRemovals: Int { state.withLock { $0.avatarRemovals } }

    public func setAvatar(mimeType: String, data: Data, in room: RoomID) async throws(HaloError) {
        if let error = state.withLock({ $0.error }) { throw error }
        state.withLock { $0.avatars.append(data) }
    }

    public func removeAvatar(in room: RoomID) async throws(HaloError) {
        if let error = state.withLock({ $0.error }) { throw error }
        state.withLock { $0.avatarRemovals += 1 }
    }

    public func setDetails(name: String, topic: String, in room: RoomID) async throws(HaloError) {
        if let error = state.withLock({ $0.error }) { throw error }
        state.withLock {
            $0.edits.append((name, topic))
            $0.details = $0.details.with(name: name, topic: topic.isEmpty ? nil : topic)
        }
    }

    public func invite(_ users: [UserID], to room: RoomID) async throws(HaloError) {
        if let error = state.withLock({ $0.error }) { throw error }
        state.withLock { $0.invites.append(users) }
    }

    public var favouriteChanges: [(room: RoomID, on: Bool)] { state.withLock { $0.favourites } }

    public func setFavourite(_ favourite: Bool, in room: RoomID) async throws(HaloError) {
        if let error = state.withLock({ $0.error }) { throw error }
        state.withLock { $0.favourites.append((room, favourite)) }
    }

    public var acceptedInvites: [RoomID] { state.withLock { $0.accepted } }
    public var declinedInvites: [RoomID] { state.withLock { $0.declined } }

    public func invitePreview(_ room: RoomID) async throws(HaloError) -> RoomInvitePreview {
        if let error = state.withLock({ $0.error }) { throw error }
        return RoomInvitePreview(name: "Preview of \(room.rawValue)", topic: "About", memberCount: 3)
    }

    public func acceptInvite(_ room: RoomID) async throws(HaloError) {
        if let error = state.withLock({ $0.error }) { throw error }
        state.withLock { $0.accepted.append(room) }
    }

    public func declineInvite(_ room: RoomID) async throws(HaloError) {
        if let error = state.withLock({ $0.error }) { throw error }
        state.withLock { $0.declined.append(room) }
    }

    public func leave(_ room: RoomID) async throws(HaloError) {
        if let error = state.withLock({ $0.error }) { throw error }
        state.withLock { $0.left.append(room) }
    }

    public func mediaGallery(in room: RoomID, limit: Int) async throws(HaloError) -> [RoomMediaItem] {
        let (items, error) = state.withLock { ($0.gallery, $0.error) }
        if let error { throw error }
        return Array(items.prefix(limit))
    }
}
