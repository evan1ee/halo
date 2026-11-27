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
        var forgotten: [RoomID] = []
        var knocks: [(address: String, reason: String?)] = []
        var previews: [String: RoomLifecyclePreview] = [:]
        var inactive: [RoomSummary] = []
        var edits: [(name: String, topic: String)] = []
        var invites: [[UserID]] = []
        var favourites: [(room: RoomID, on: Bool)] = []
        var accepted: [RoomID] = []
        var declined: [RoomID] = []
        var gallery: [RoomMediaItem] = []
        var exportedMessages: [RoomExportMessage] = []
    }
    private let state: Mutex<State>

    public init(
        details: RoomDetails,
        members: [RoomMemberInfo] = [],
        gallery: [RoomMediaItem] = [],
        exportedMessages: [RoomExportMessage] = []
    ) {
        state = Mutex(State(details: details, members: members, gallery: gallery, exportedMessages: exportedMessages))
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
        state.withLock {
            $0.left.append(room)
            $0.inactive.removeAll { $0.id == room && $0.membership == .knocked }
        }
    }

    public var forgottenRooms: [RoomID] { state.withLock { $0.forgotten } }
    public var knockedAddresses: [(address: String, reason: String?)] { state.withLock { $0.knocks } }
    public func setPreview(_ preview: RoomLifecyclePreview, for address: String) {
        state.withLock { $0.previews[address] = preview }
    }
    public func setInactiveRooms(_ rooms: [RoomSummary]) {
        state.withLock { $0.inactive = rooms }
    }

    public func forget(_ room: RoomID) async throws(HaloError) {
        if let error = state.withLock({ $0.error }) { throw error }
        state.withLock {
            $0.forgotten.append(room)
            $0.inactive.removeAll { $0.id == room }
        }
    }

    public func previewRoom(address: String) async throws(HaloError) -> RoomLifecyclePreview {
        let (preview, error) = state.withLock { ($0.previews[address], $0.error) }
        if let error { throw error }
        if let preview { return preview }
        return RoomLifecyclePreview(roomID: try? RoomID(address), address: address, name: "Room \(address)", joinAccess: .public)
    }

    public func knock(address: String, reason: String?) async throws(HaloError) -> RoomID {
        if let error = state.withLock({ $0.error }) { throw error }
        return try state.withLock { s throws(HaloError) in
            s.knocks.append((address, reason))
            let fallback = try RoomID("!knocked:example.org")
            let id = s.previews[address]?.roomID ?? (try? RoomID(address)) ?? fallback
            if let existing = s.previews[address] {
                s.previews[address] = RoomLifecyclePreview(
                    roomID: id, address: existing.address, name: existing.name, topic: existing.topic,
                    avatar: existing.avatar, memberCount: existing.memberCount, membership: .knocked, joinAccess: existing.joinAccess
                )
            }
            return id
        }
    }

    public func inactiveRooms() async -> [RoomSummary] {
        state.withLock { $0.inactive }
    }

    public func mediaGallery(in room: RoomID, limit: Int) async throws(HaloError) -> [RoomMediaItem] {
        let (items, error) = state.withLock { ($0.gallery, $0.error) }
        if let error { throw error }
        return Array(items.prefix(limit))
    }

    public func openMediaGallery(in room: RoomID) async throws(HaloError) -> any RoomMediaGallerySession {
        let (items, error) = state.withLock { ($0.gallery, $0.error) }
        if let error { throw error }
        return FakeRoomMediaGallerySession(items: items, errorProvider: { [weak self] in
            self?.state.withLock { $0.error }
        })
    }

    public func exportMessages(in room: RoomID, limit: Int) async throws(HaloError) -> [RoomExportMessage] {
        let (items, error) = state.withLock { ($0.exportedMessages, $0.error) }
        if let error { throw error }
        return Array(items.suffix(limit))
    }
}

private actor FakeRoomMediaGallerySession: RoomMediaGallerySession {
    private let items: [RoomMediaItem]
    private let errorProvider: @Sendable () -> HaloError?
    private var offset = 0
    private var isClosed = false

    init(items: [RoomMediaItem], errorProvider: @escaping @Sendable () -> HaloError?) {
        self.items = items
        self.errorProvider = errorProvider
    }

    func nextPage(limit: Int) async throws(HaloError) -> MediaGalleryPage {
        if let error = errorProvider() { throw error }
        guard !isClosed, offset < items.count, limit > 0 else {
            return MediaGalleryPage(items: [], hasMore: false)
        }
        let end = min(items.count, offset + limit)
        let slice = Array(items[offset..<end])
        offset = end
        return MediaGalleryPage(items: slice, hasMore: offset < items.count)
    }

    func close() async {
        isClosed = true
    }
}
