import Foundation
import HaloApplication
import HaloDomain
import HaloFoundation
import Observation

/// The room list for the signed-in user. It shows the count and the room names (M0's exit signal); a row selects a room for the timeline. Filters and unread
/// badges come with the read-state work (M3).
///
/// It follows the session: the list is subscribed while a session is ready and stopped otherwise.
@MainActor @Observable
public final class RoomListViewModel {
    public struct Row: Equatable, Identifiable, Sendable {
        public let id: RoomID
        public let name: String
        /// What the unread indicator shows (`ReadStatePolicy`); `.none` for a read room.
        public let display: DisplayCount
        /// Unread without needing attention (quiet room): the title is shown bold, with no badge.
        public let hasUnread: Bool
        /// An invitation not yet answered: the row offers Accept and Decline instead of opening the room.
        public let isInvite: Bool
        public let isFavourite: Bool
        public let isMuted: Bool
        /// The time of the newest event; `nil` for a room without one.
        public let lastActivity: Date?
        /// The newest message as one line ("Ann: see you at 5"); `nil` when there is none to show.
        public let preview: String?
        /// The room's avatar image; `nil` shows the initials.
        public let avatar: MediaRef?
        /// For an invitation: who sent it.
        public let inviter: String?

        public init(
            id: RoomID, name: String, display: DisplayCount = .none, hasUnread: Bool = false, isInvite: Bool = false,
            isFavourite: Bool = false, isMuted: Bool = false, lastActivity: Date? = nil, preview: String? = nil,
            avatar: MediaRef? = nil, inviter: String? = nil
        ) {
            self.inviter = inviter
            self.avatar = avatar
            self.preview = preview
            self.isFavourite = isFavourite
            self.isMuted = isMuted
            self.lastActivity = lastActivity
            self.isInvite = isInvite
            self.id = id
            self.name = name
            self.display = display
            self.hasUnread = hasUnread
        }
    }

    public enum Content: Equatable {
        case idle
        case loading
        case loaded(count: Int, rows: [Row])
        case failed(String)
    }

    public struct SyncNotice: Equatable, Sendable {
        public let text: String
        public let isOffline: Bool
    }

    public private(set) var content: Content = .idle
    /// Joined room IDs currently known to the room list (used by state restoration to prune left rooms, NAVIGATION §4).
    public var joinedRoomIDs: Set<RoomID> {
        guard case .loaded(_, let rows) = content else { return [] }
        return Set(rows.filter { !$0.isInvite }.map(\.id))
    }
    /// Non-nil while sync is offline or retrying after an error (ROOM_LIST FR-7); `nil` while healthy.
    public private(set) var syncNotice: SyncNotice?

    /// The list filter (ROOM_LIST FR-2). Applied here to the rooms the coordinator holds; with classic sync every room is present.
    public var filter: RoomListFilter = .all {
        didSet {
            if filter != oldValue {
                visibleLimit = pageSize
                Task { await listChanged(lastStatus) }
            }
        }
    }

    /// What the active Focus allows (M16, D90); `nil` when no Focus filter is on. It overrides `filter` until the person
    /// taps "Show all chats" or the Focus ends; their own `filter` choice is untouched.
    public private(set) var focusChats: FocusChats?
    private var focusSuspended = false

    /// The filter the list applies: the Focus's while it is on and not set aside, else the person's.
    public var effectiveFilter: RoomListFilter {
        if let focusChats, !focusSuspended { return focusChats.listFilter }
        return filter
    }

    /// Whether the list is currently narrowed by a Focus (for the banner).
    public var isFocusFiltering: Bool { focusChats != nil && !focusSuspended }

    /// Called when the Focus filter turns on, changes or off (`nil`).
    public func setFocus(_ chats: FocusChats?) {
        guard chats != focusChats else { return }
        focusChats = chats
        focusSuspended = false
        visibleLimit = pageSize
        Task { await listChanged(lastStatus) }
    }

    /// "Show all chats": sets the Focus filter aside until the Focus changes.
    public func suspendFocusFilter() {
        guard isFocusFiltering else { return }
        focusSuspended = true
        visibleLimit = pageSize
        Task { await listChanged(lastStatus) }
    }

    /// How many matching rows are rendered at once before the user scrolls to the bottom of the list (`ROADMAP.md` M5 performance pass).
    public let pageSize: Int
    public private(set) var visibleLimit: Int
    /// Whether more matching rooms exist below the currently rendered slice (`rows.count < totalMatching`).
    public private(set) var canShowMore = false

    /// Expands the rendered slice by one `pageSize` when the bottom of the room list is reached.
    public func showMore() async {
        guard canShowMore else { return }
        visibleLimit += pageSize
        await listChanged(lastStatus)
    }

    private let session: SessionCoordinator
    private let rooms: RoomListCoordinator
    private let readState: ReadStateCoordinator
    private let sync: SyncCoordinator?
    private let receipts: ReadReceiptCoordinator?
    private let actions: (any RoomPort)?
    /// Told which rooms are at the top of the list, so their timelines can be prepared before they are opened.
    public var warm: (@Sendable ([RoomID]) async -> Void)?
    /// User IDs whose recognised bot messages render concise card previews in the room list (Settings → Bots, ROOM_LIST FR-3).
    public var botSenders: @MainActor () -> Set<String> = { [] }
    private var warmedTop: [RoomID] = []
    private let media: MediaLoader?

    /// The avatar's image bytes (a small thumbnail); `nil` when there is no loader or the download failed, so the row keeps its initials.
    public func avatarData(_ ref: MediaRef) async -> Data? {
        guard let media else { return nil }
        return try? await media.thumbnail(ref, width: 96, height: 96)
    }
    private var tasks: [Task<Void, Never>] = []
    private var hasStarted = false
    private var roomStates: [RoomID: RoomReadState] = [:]
    private var lastStatus: RoomListCoordinator.Status = .idle

    /// Set when a swipe or invitation action fails; cleared by the next successful action or when dismissed.
    public private(set) var actionError: String?

    public func dismissActionError() { actionError = nil }

    /// Restarts the room-list subscription after a failure (ROOM_LIST §9).
    public func retry() async { await rooms.start() }

    /// Re-renders loaded rows (for example after returning from Settings → Bots so bot-card previews update).
    public func refresh() async {
        if case .loaded = lastStatus { await listChanged(lastStatus) }
    }

    public init(
        session: SessionCoordinator, rooms: RoomListCoordinator, readState: ReadStateCoordinator,
        sync: SyncCoordinator? = nil, receipts: ReadReceiptCoordinator? = nil,
        actions: (any RoomPort)? = nil, media: MediaLoader? = nil,
        pageSize: Int = 50
    ) {
        self.pageSize = max(1, pageSize)
        self.visibleLimit = max(1, pageSize)
        self.media = media
        self.actions = actions
        self.session = session
        self.rooms = rooms
        self.readState = readState
        self.sync = sync
        self.receipts = receipts
    }

    /// "Mark as read" (swipe, ROOM_LIST FR-6).
    public func markRead(_ room: RoomID) async {
        guard let receipts else { return }
        let latest = await rooms.rooms.first { $0.id == room }?.latestEvent?.timestamp
        await perform { () async throws(HaloError) in try await receipts.markRoomRead(room, latestEventTime: latest) }
    }

    /// "Mark as unread" (swipe, ROOM_LIST FR-6).
    public func markUnread(_ room: RoomID) async {
        guard let receipts else { return }
        await perform { () async throws(HaloError) in try await receipts.markRoomUnread(room) }
    }

    /// Accepts an invitation (ROOM_MANAGEMENT FR-6); the room then arrives as joined with the next sync.
    public func acceptInvite(_ room: RoomID) async {
        guard let actions else { return }
        await perform { () async throws(HaloError) in try await actions.acceptInvite(room) }
    }

    /// What the user has asked to see of invitations, by room (ROOM_MANAGEMENT FR-6).
    public private(set) var invitePreviews: [RoomID: RoomInvitePreview] = [:]

    /// Loads the room's topic and size for an invitation row; a failure says it was the details that couldn't be loaded.
    public func previewInvite(_ room: RoomID) async {
        guard let actions else { return }
        do {
            invitePreviews[room] = try await actions.invitePreview(room)
            actionError = nil
        } catch {
            actionError = "The invitation's details couldn't be loaded."
        }
    }

    /// Declines an invitation.
    public func declineInvite(_ room: RoomID) async {
        guard let actions else { return }
        await perform { () async throws(HaloError) in try await actions.declineInvite(room) }
    }

    /// Swipe: add or remove a favourite (ROOM_LIST FR-6).
    public func toggleFavourite(_ row: Row) async {
        guard let actions else { return }
        await perform { () async throws(HaloError) in try await actions.setFavourite(!row.isFavourite, in: row.id) }
    }

    /// Swipe: mute, or back to all messages when already muted (ROOM_LIST FR-6).
    public func toggleMute(_ row: Row) async {
        guard let actions else { return }
        await perform { () async throws(HaloError) in try await actions.setNotificationMode(row.isMuted ? .allMessages : .mute, in: row.id) }
    }

    private func perform(_ action: () async throws(HaloError) -> Void) async {
        do { try await action(); actionError = nil } catch { actionError = "That didn't work. Try again." }
    }

    isolated deinit { tasks.forEach { $0.cancel() } }

    /// Starts following the session, the list, and the single read-state stream (R-05). Call once when the screen appears.
    public func start() async {
        guard !hasStarted else { return }  // the app root and the view both call it
        hasStarted = true
        let sessionStates = await session.states()
        let listStatuses = await rooms.statuses()
        let readStates = await readState.states()
        let summaries = await rooms.summaryChanges()
        var follow: [Task<Void, Never>] = []
        if let sync {
            let syncStatuses = await sync.statuses()
            follow.append(Task { [weak self] in
                for await status in syncStatuses { self?.syncChanged(status) }
            })
        }
        follow.append(Task { [weak self] in
            for await states in readStates { await self?.readStatesChanged(states) }
        })
        // Renames, favourites and new latest events don't change the read states.
        follow.append(Task { [weak self] in
            for await _ in summaries { await self?.summariesChanged() }
        })
        tasks = follow + [
            Task { [weak self] in
                for await state in sessionStates { await self?.sessionChanged(state) }
            },
            Task { [weak self] in
                for await status in listStatuses { await self?.listChanged(status) }
            },
        ]
    }

    func sessionChanged(_ state: SessionCoordinator.State) async {
        if case .ready = state { await rooms.start() } else { await rooms.stop() }
    }

    func syncChanged(_ status: SyncStatus) {
        syncNotice = Self.syncNotice(for: status)
    }

    static func syncNotice(for status: SyncStatus) -> SyncNotice? {
        switch status {
        case .offline: SyncNotice(text: "Offline — waiting to reconnect", isOffline: true)
        case .failed: SyncNotice(text: "Sync interrupted — retrying…", isOffline: false)
        case .idle, .running, .stopped: nil
        }
    }

    func summariesChanged() async {
        if case .loaded = lastStatus { await listChanged(lastStatus) }
    }

    func readStatesChanged(_ states: [RoomID: RoomReadState]) async {
        roomStates = states
        if case .loaded = lastStatus { await listChanged(lastStatus) }
    }

    /// Whether a room belongs to the chosen filter (ROOM_LIST FR-2); an invitation shows under All and Invites only.
    static func includes(_ filter: RoomListFilter, room: RoomSummary, row: Row) -> Bool {
        switch filter {
        case .all: true
        case .unread: !row.isInvite && (row.hasUnread || row.display != .none)
        case .people: room.membership == .joined && room.isDirect
        case .rooms: room.membership == .joined && !room.isDirect
        case .favourites: room.membership == .joined && room.isFavourite
        case .invites: row.isInvite
        }
    }

    func listChanged(_ status: RoomListCoordinator.Status) async {
        lastStatus = status
        switch status {
        case .idle: content = .idle
        case .loading: content = .loading
        case .loaded(let count):
            let bots = botSenders()
            let currentRooms = await rooms.rooms
            let currentStates = await readState.roomStates
            roomStates = currentStates
            let rows = currentRooms.map { room in
                let state = currentStates[room.id]
                return Row(
                    id: room.id, name: room.name ?? "Unnamed room",
                    display: state?.display ?? .none, hasUnread: state?.hasUnread ?? false,
                    isInvite: room.membership == .invited,
                    isFavourite: room.isFavourite, isMuted: room.read.mode == .mute, lastActivity: room.latestEvent?.timestamp,
                    preview: room.preview?.line(isDirect: room.isDirect, botSenders: bots), avatar: room.avatar, inviter: room.inviter)
            }
            let matching = zip(currentRooms, rows).filter { Self.includes(effectiveFilter, room: $0.0, row: $0.1) }.map(\.1)
            let visible = Array(matching.prefix(visibleLimit))
            canShowMore = matching.count > visible.count
            content = .loaded(count: effectiveFilter == .all ? count : matching.count, rows: visible)
            let invited = Set(rows.filter(\.isInvite).map(\.id))
            invitePreviews = invitePreviews.filter { invited.contains($0.key) }  // accepted or declined: the preview goes with it
            // Only a change at the top of the list asks for new timelines; most sync updates leave it as it is.
            let top = Array(matching.filter { !$0.isInvite }.prefix(6).map(\.id))
            if let warm, top != warmedTop {
                warmedTop = top
                Task { await warm(top) }
            }
        case .failed: content = .failed("The room list couldn't be loaded.")
        }
    }
}
