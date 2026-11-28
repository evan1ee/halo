import Foundation
import HaloDomain
import HaloFoundation
import MatrixRustSDK
import Synchronization

/// `RoomPort` over `Room`, `RoomMembersIterator` and the client's `NotificationSettings` (ROOM_MANAGEMENT FR-1…FR-4, F-FFI-7/18).
public final class MatrixRoomPort: RoomPort {
    private let session: MatrixSessionPort

    public init(session: MatrixSessionPort) { self.session = session }

    public func details(_ id: RoomID) async throws(HaloError) -> RoomDetails {
        let room = try await session.room(id)
        let client = try await session.signedInClient()
        let encrypted = room.encryptionState() == .encrypted
        let direct = await room.isDirect()
        let mode: RoomNotificationMode
        do {
            mode = try await client.getNotificationSettings().getRoomNotificationSettings(roomId: id.rawValue, isEncrypted: encrypted, isOneToOne: direct).mode
        } catch { throw ErrorMapper.map(error) }
        // Permissions: unknown power levels mean "no" (the server still has the last word).
        var canEdit = false, canInvite = false
        if let levels = try? await room.getPowerLevels(), let own = try? await session.ownUserID() {  // best-effort: fail-closed; hides edit/invite controls if power levels can't be read
            canEdit = (try? levels.canUserSendState(userId: own, stateEvent: .roomName)) == true && (try? levels.canUserSendState(userId: own, stateEvent: .roomTopic)) == true
            canInvite = (try? levels.canUserInvite(userId: own)) == true
        }
        let successor: RoomSuccessor? = room.successorRoom().flatMap { s in
            (try? RoomID(s.roomId)).map { RoomSuccessor(roomID: $0, reason: s.reason) }
        }
        let resolvedMembership = await Self.resolvedMembership(of: room)
        return RoomDetails(
            id: id, name: room.displayName(), topic: room.topic(), isDirect: direct, isEncrypted: encrypted,
            joinedMemberCount: Int(room.joinedMembersCount()), notificationMode: Self.choice(mode), canEditDetails: canEdit, canInvite: canInvite,
            avatar: MatrixRoomListPort.avatar(room.avatarUrl()),
            successor: successor,
            membership: resolvedMembership)
    }

    /// Upper bound on total members read across chunks in `members(_:limit:)` so huge public rooms don't block the UI thread
    /// scanning tens of thousands of entries before sorting (`ROADMAP.md` M5 performance pass).
    static let maxScannedMembers = 2_000

    public func members(_ id: RoomID, limit: Int) async throws(HaloError) -> [RoomMemberInfo] {
        let room = try await session.room(id)
        let own = try await session.ownUserID()
        let scanCap = max(limit, Self.maxScannedMembers)
        var result: [RoomMemberInfo] = []
        do {
            let iterator = try await room.members()
            while result.count < scanCap, let chunk = iterator.nextChunk(chunkSize: 200) {
                for member in chunk where member.membership == .join || member.membership == .invite {
                    result.append(RoomMemberInfo(userID: member.userId, displayName: member.displayName, role: Self.role(member.suggestedRoleForPowerLevel), isInvited: member.membership == .invite, isMe: member.userId == own, avatar: MatrixRoomListPort.avatar(member.avatarUrl)))
                    if result.count >= scanCap { break }
                }
            }
        } catch { throw ErrorMapper.map(error) }
        let rank: (HaloDomain.RoomMemberRole) -> Int = { switch $0 { case .administrator: 0; case .moderator: 1; case .user: 2 } }
        result.sort { ($0.isInvited ? 1 : 0, rank($0.role), $0.title.lowercased()) < ($1.isInvited ? 1 : 0, rank($1.role), $1.title.lowercased()) }
        return Array(result.prefix(limit))
    }

    public func setNotificationMode(_ mode: RoomNotificationChoice, in id: RoomID) async throws(HaloError) {
        let client = try await session.signedInClient()
        let sdkMode: RoomNotificationMode = switch mode { case .allMessages: .allMessages; case .mentionsAndKeywords: .mentionsAndKeywordsOnly; case .mute: .mute }
        do { try await client.getNotificationSettings().setRoomNotificationMode(roomId: id.rawValue, mode: sdkMode) } catch { throw ErrorMapper.map(error) }
    }

    public func setDetails(name: String, topic: String, in id: RoomID) async throws(HaloError) {
        let room = try await session.room(id)
        do {
            try await room.setName(name: name)
            try await room.setTopic(topic: topic)
        } catch { throw ErrorMapper.map(error) }
    }

    public func setAvatar(mimeType: String, data: Data, in id: RoomID) async throws(HaloError) {
        let room = try await session.room(id)
        do { try await room.uploadAvatar(mimeType: mimeType, data: data, mediaInfo: nil) } catch { throw ErrorMapper.map(error) }
    }

    public func removeAvatar(in id: RoomID) async throws(HaloError) {
        let room = try await session.room(id)
        do { try await room.removeAvatar() } catch { throw ErrorMapper.map(error) }
    }

    public func invite(_ users: [UserID], to id: RoomID) async throws(HaloError) {
        let room = try await session.room(id)
        do { for user in users { try await room.inviteUserById(userId: user.rawValue) } } catch { throw ErrorMapper.map(error) }
    }

    public func acceptInvite(_ id: RoomID) async throws(HaloError) {
        let client = try await session.signedInClient()
        do { _ = try await client.joinRoomById(roomId: id.rawValue) } catch { throw ErrorMapper.map(error) }
    }

    public func invitePreview(_ id: RoomID) async throws(HaloError) -> RoomInvitePreview {
        let client = try await session.signedInClient()
        do {
            let info = try await client.getRoomPreviewFromRoomId(roomId: id.rawValue, viaServers: []).info()
            return RoomInvitePreview(
                name: info.name, topic: info.topic, memberCount: info.numJoinedMembers > 0 ? Int(clamping: info.numJoinedMembers) : nil,
                avatar: MatrixRoomListPort.avatar(info.avatarUrl))
        } catch { throw ErrorMapper.map(error) }
    }

    public func declineInvite(_ id: RoomID) async throws(HaloError) {
        let room = try await session.room(id)
        do { try await room.leave() } catch { throw ErrorMapper.map(error) }
    }

    public func setFavourite(_ favourite: Bool, in id: RoomID) async throws(HaloError) {
        let room = try await session.room(id)
        do { try await room.setIsFavourite(isFavourite: favourite, tagOrder: nil) } catch { throw ErrorMapper.map(error) }
    }

    public func leave(_ id: RoomID) async throws(HaloError) {
        let room = try await session.room(id)
        do { try await room.leave() } catch { throw ErrorMapper.map(error) }
    }

    public func forget(_ id: RoomID) async throws(HaloError) {
        let room = try await session.room(id)
        do { try await room.forget() } catch { throw ErrorMapper.map(error) }
    }

    public func previewRoom(address: String) async throws(HaloError) -> RoomLifecyclePreview {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw .invalidInput("EMPTY_ROOM_ADDRESS") }
        let client = try await session.signedInClient()
        do {
            let preview: RoomPreview
            if trimmed.hasPrefix("#") {
                preview = try await client.getRoomPreviewFromRoomAlias(roomAlias: trimmed)
            } else {
                preview = try await client.getRoomPreviewFromRoomId(roomId: trimmed, viaServers: [])
            }
            let info = preview.info()
            return RoomLifecyclePreview(
                roomID: try? RoomID(info.roomId),
                address: info.canonicalAlias ?? trimmed,
                name: info.name,
                topic: info.topic,
                avatar: MatrixRoomListPort.avatar(info.avatarUrl),
                memberCount: info.numJoinedMembers > 0 ? Int(clamping: info.numJoinedMembers) : nil,
                membership: info.membership.map(Self.membership),
                joinAccess: Self.joinAccess(info.joinRule)
            )
        } catch {
            // If the room is already known locally (e.g. banned or left invite-only room where the server refuses preview),
            // surface the local state honestly instead of failing silently.
            if let localID = try? RoomID(trimmed),
               let local = client.rooms().first(where: { $0.id() == localID.rawValue }) {
                let resolved = await Self.resolvedMembership(of: local)
                return RoomLifecyclePreview(
                    roomID: localID,
                    address: trimmed,
                    name: local.displayName(),
                    topic: local.topic(),
                    avatar: MatrixRoomListPort.avatar(local.avatarUrl()),
                    memberCount: local.joinedMembersCount() > 0 ? Int(clamping: local.joinedMembersCount()) : nil,
                    membership: resolved,
                    joinAccess: .unknown
                )
            }
            throw ErrorMapper.map(error)
        }
    }

    public func knock(address: String, reason: String?) async throws(HaloError) -> RoomID {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw .invalidInput("EMPTY_ROOM_ADDRESS") }
        let cleanReason = reason?.trimmingCharacters(in: .whitespacesAndNewlines)
        let client = try await session.signedInClient()
        do {
            let room = try await client.knock(
                roomIdOrAlias: trimmed,
                reason: (cleanReason?.isEmpty == false) ? cleanReason : nil,
                serverNames: []
            )
            return try RoomID(room.id())
        } catch let error as HaloError {
            throw error
        } catch {
            throw ErrorMapper.map(error)
        }
    }

    public func inactiveRooms() async -> [RoomSummary] {
        guard let client = try? await session.signedInClient() else { return [] }  // best-effort: returns empty when signed out
        let rooms = client.rooms().filter { !$0.isSpace() && [.knocked, .left, .banned].contains($0.membership()) }
        var summaries: [RoomSummary] = []
        for room in rooms {
            guard let id = try? RoomID(room.id()) else { continue }
            let info = try? await room.roomInfo()  // best-effort: metadata falls back to room accessors
            let successor: RoomSuccessor? = (info?.successorRoom ?? room.successorRoom()).flatMap { s in
                (try? RoomID(s.roomId)).map { RoomSuccessor(roomID: $0, reason: s.reason) }
            }
            let resolved = await Self.resolvedMembership(of: room)
            summaries.append(RoomSummary(
                id: id,
                name: room.displayName(),
                isDirect: info?.isDirect ?? false,
                isEncrypted: room.encryptionState() == .encrypted,
                membership: resolved,
                avatar: MatrixRoomListPort.avatar(room.avatarUrl()),
                successor: successor
            ))
        }
        return summaries.sorted { ($0.name ?? $0.id.rawValue).localizedCaseInsensitiveCompare($1.name ?? $1.id.rawValue) == .orderedAscending }
    }

    /// Classic `/v3/sync` places both left and banned rooms in `rooms.leave`; when `room.membership()` reports `.left`,
    /// inspect the locally cached own `m.room.member` state (without a network `/members` call that 403s when banned)
    /// to distinguish a ban from an ordinary leave.
    private static func resolvedMembership(of room: Room) async -> HaloDomain.Membership {
        let base = membership(room.membership())
        guard base == .left else { return base }
        let ownUserID = room.ownUserId()
        if let iterator = try? await room.membersNoSync() {  // best-effort: falls back to .left if local cache is unavailable
            while let chunk = iterator.nextChunk(chunkSize: 200) {
                if let own = chunk.first(where: { $0.userId == ownUserID }) {
                    return own.membership == .ban ? .banned : .left
                }
            }
        }
        return base
    }

    private static func membership(_ m: MatrixRustSDK.Membership) -> HaloDomain.Membership {
        switch m {
        case .joined: .joined
        case .invited: .invited
        case .knocked: .knocked
        case .left: .left
        case .banned: .banned
        }
    }

    private static func joinAccess(_ rule: JoinRule?) -> RoomJoinAccess {
        guard let rule else { return .unknown }
        switch rule {
        case .public: return .public
        case .knock, .knockRestricted: return .knock
        case .invite, .private: return .inviteOnly
        case .restricted: return .restricted
        case .custom: return .unknown
        }
    }

    public func mediaGallery(in id: RoomID, limit: Int) async throws(HaloError) -> [RoomMediaItem] {
        let gallery = try await openMediaGallery(in: id)
        do {
            let page = try await gallery.nextPage(limit: limit)
            await gallery.close()
            return page.items
        } catch {
            await gallery.close()
            throw error
        }
    }

    public func openMediaGallery(in id: RoomID) async throws(HaloError) -> any RoomMediaGallerySession {
        let room = try await session.room(id)
        let own = try await session.ownUserID()
        let config = TimelineConfiguration(
            focus: .live(hideThreadedEvents: false),
            filter: .onlyMessage(types: [.image, .video, .audio, .file]),
            internalIdPrefix: "gallery-\(UUID().uuidString)",
            dateDividerMode: .daily,
            trackReadReceipts: .disabled,
            reportUtds: false)
        do {
            let timeline = try await room.timelineWithConfiguration(configuration: config)
            let collector = GalleryCollector(ownUserID: own)
            let handle = await timeline.addListener(listener: collector)
            return MatrixRoomMediaGallerySession(timeline: timeline, collector: collector, handle: handle)
        } catch { throw ErrorMapper.map(error) }
    }

    public func exportMessages(in id: RoomID, limit: Int) async throws(HaloError) -> [RoomExportMessage] {
        let room = try await session.room(id)
        let own = try await session.ownUserID()
        let config = TimelineConfiguration(
            focus: .live(hideThreadedEvents: false),
            filter: .all,
            internalIdPrefix: "export-\(UUID().uuidString)",
            dateDividerMode: .daily,
            trackReadReceipts: .disabled,
            reportUtds: false)  // `true` needs a hook on the client; without one the SDK refuses the timeline
        do {
            let timeline = try await room.timelineWithConfiguration(configuration: config)
            let (raw, continuation) = AsyncStream<[MatrixRustSDK.TimelineDiff]>.makeStream(bufferingPolicy: .unbounded)
            let handle = await timeline.addListener(listener: GalleryListener(continuation))
            defer { handle.cancel(); continuation.finish() }

            // Older history that can't be loaded fails the export: a file that silently stops part-way would pass for the whole
            // room (AGENTS §4.4, audit S-6). Up to 10 pages; a room with more exports its newest `limit` messages, as documented.
            let paginateTask = Task { () -> HaloError? in
                defer { continuation.finish() }
                do {
                    for _ in 0..<10 {
                        if try await timeline.paginateBackwards(numEvents: 50) { break }
                    }
                    return nil
                } catch {
                    return ErrorMapper.map(error)
                }
            }
            defer { paginateTask.cancel() }

            var items: [HaloDomain.TimelineItem] = []
            var filled = false
            for await batch in raw {
                for update in batch {
                    try ListReducer.apply(TimelineMapper.map(update, ownUserID: own), to: &items)
                }
                if items.count >= limit {
                    filled = true
                    break
                }
            }
            if !filled, let failure = await paginateTask.value { throw failure }
            var messages: [RoomExportMessage] = []
            for item in items {
                guard case .event(let event) = item.content, let eventID = event.eventID else { continue }
                guard let mapped = Self.exportMessage(event, eventID: eventID) else { continue }
                messages.append(mapped)
            }
            if messages.count > limit {
                return Array(messages.suffix(limit))
            }
            return messages
        } catch { throw ErrorMapper.map(error) }
    }

    private static func exportMessage(_ event: HaloDomain.TimelineEvent, eventID: EventID) -> RoomExportMessage? {
        let senderName = event.senderName ?? event.sender?.rawValue ?? "Unknown"
        let senderID = event.sender?.rawValue
        switch event.kind {
        case .text(let body, _):
            return RoomExportMessage(eventID: eventID.rawValue, senderID: senderID, senderName: senderName, timestamp: event.timestamp, kind: "text", body: body)
        case .notice(let body, _):
            return RoomExportMessage(eventID: eventID.rawValue, senderID: senderID, senderName: senderName, timestamp: event.timestamp, kind: "notice", body: body)
        case .emote(let body, _):
            return RoomExportMessage(eventID: eventID.rawValue, senderID: senderID, senderName: senderName, timestamp: event.timestamp, kind: "emote", body: body)
        case .media(let attachment):
            let kindName: String = switch attachment.kind {
            case .image: "image"
            case .video: "video"
            case .audio: "audio"
            case .file: "file"
            }
            return RoomExportMessage(eventID: eventID.rawValue, senderID: senderID, senderName: senderName, timestamp: event.timestamp, kind: kindName, body: attachment.body, mediaFilename: attachment.body)
        case .sticker(let body, _, _, _):
            return RoomExportMessage(eventID: eventID.rawValue, senderID: senderID, senderName: senderName, timestamp: event.timestamp, kind: "sticker", body: body)
        case .location(let body, let geoURI):
            return RoomExportMessage(eventID: eventID.rawValue, senderID: senderID, senderName: senderName, timestamp: event.timestamp, kind: "location", body: "\(body) (\(geoURI))")
        case .poll(let details):
            return RoomExportMessage(eventID: eventID.rawValue, senderID: senderID, senderName: senderName, timestamp: event.timestamp, kind: "poll", body: details.question)
        case .redacted:
            return RoomExportMessage(eventID: eventID.rawValue, senderID: senderID, senderName: senderName, timestamp: event.timestamp, kind: "redacted", body: "[Message deleted]")
        case .undecryptable:
            return RoomExportMessage(eventID: eventID.rawValue, senderID: senderID, senderName: senderName, timestamp: event.timestamp, kind: "undecryptable", body: "[Unable to decrypt]")
        case .membership, .call, .otherState, .unsupported:
            return nil
        }
    }

    static func choice(_ mode: RoomNotificationMode) -> RoomNotificationChoice {
        switch mode { case .allMessages: .allMessages; case .mentionsAndKeywordsOnly: .mentionsAndKeywords; case .mute: .mute }
    }

    static func role(_ role: MatrixRustSDK.RoomMemberRole) -> HaloDomain.RoomMemberRole {
        switch role { case .creator, .administrator: .administrator; case .moderator: .moderator; case .user: .user }
    }
}

private final class GalleryListener: TimelineListener {
    private let continuation: AsyncStream<[MatrixRustSDK.TimelineDiff]>.Continuation
    init(_ continuation: AsyncStream<[MatrixRustSDK.TimelineDiff]>.Continuation) { self.continuation = continuation }
    func onUpdate(diff: [MatrixRustSDK.TimelineDiff]) { continuation.yield(diff) }
}

/// Maps gallery timeline diffs directly into domain items on the SDK callback without blocking or re-entering FFI (AGENTS §8).
final class GalleryCollector: TimelineListener, Sendable {
    private struct State {
        var items: [HaloDomain.TimelineItem] = []
        var updates = 0
        var failure: HaloError?
    }

    private let ownUserID: String
    private let sleep: @Sendable (Duration) async -> Void
    private let state = Mutex(State())

    init(ownUserID: String, sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }) {
        self.ownUserID = ownUserID
        self.sleep = sleep
    }

    var updates: Int { state.withLock { $0.updates } }

    func onUpdate(diff: [MatrixRustSDK.TimelineDiff]) {
        let mapped = diff.map { TimelineMapper.map($0, ownUserID: ownUserID) }
        applyMapped(mapped)
    }

    func applyMapped(_ mapped: [HaloDomain.TimelineDiff]) {
        state.withLock { current in
            for update in mapped {
                if case .reset = update { current.failure = nil }
                do {
                    try ListReducer.apply(update, to: &current.items)
                } catch {
                    // Record reducer corruption instead of silently returning an incomplete media gallery (audit S-6).
                    current.failure = ErrorMapper.map(error)
                }
            }
            current.updates += 1
        }
    }

    /// Waits briefly for the SDK's asynchronous listener task to deliver diffs after `addListener` or `paginateBackwards`.
    func settle(after count: Int, waitTicks: Int = 50, quietTicks: Int = 20) async {
        for _ in 0..<waitTicks where updates <= count {
            await sleep(.milliseconds(1))
        }
        guard updates > count else { return }
        var last = updates
        for _ in 0..<quietTicks {
            await sleep(.milliseconds(10))
            let current = updates
            if current == last { return }
            last = current
        }
    }

    func mediaItemsNewestFirst() throws(HaloError) -> [RoomMediaItem] {
        let snapshot = try state.withLock { current throws(HaloError) -> [HaloDomain.TimelineItem] in
            if let failure = current.failure { throw failure }
            return current.items
        }
        var result: [RoomMediaItem] = []
        result.reserveCapacity(snapshot.count)
        for item in snapshot.reversed() {
            guard case .event(let event) = item.content,
                  let eventID = event.eventID,
                  case .media(let attachment) = event.kind else { continue }
            result.append(RoomMediaItem(
                eventID: eventID,
                senderName: event.senderName ?? event.sender?.rawValue ?? "Unknown",
                timestamp: event.timestamp,
                attachment: attachment))
        }
        return result
    }
}

/// Paged room media gallery session over a filtered SDK timeline (M19-5).
private actor MatrixRoomMediaGallerySession: RoomMediaGallerySession {
    private let timeline: Timeline
    private let collector: GalleryCollector
    private var handle: TaskHandle?
    private var deliveredIDs: Set<EventID> = []
    private var settledInitial = false
    private var reachedStart = false
    private var isClosed = false

    private static let eventsPerStep: UInt16 = 40
    private static let maxStepsPerPage = 5

    init(timeline: Timeline, collector: GalleryCollector, handle: TaskHandle) {
        self.timeline = timeline
        self.collector = collector
        self.handle = handle
    }

    deinit {
        handle?.cancel()
    }

    func nextPage(limit: Int) async throws(HaloError) -> MediaGalleryPage {
        guard !isClosed, limit > 0 else { return MediaGalleryPage(items: [], hasMore: false) }
        if !settledInitial {
            settledInitial = true
            await collector.settle(after: 0)
        }
        var unseen = try collector.mediaItemsNewestFirst().filter { !deliveredIDs.contains($0.eventID) }
        var steps = 0
        while unseen.count < limit && !reachedStart && steps < Self.maxStepsPerPage {
            let seen = collector.updates
            do {
                reachedStart = try await timeline.paginateBackwards(numEvents: Self.eventsPerStep)
            } catch {
                throw ErrorMapper.map(error)
            }
            await collector.settle(after: seen)
            steps += 1
            unseen = try collector.mediaItemsNewestFirst().filter { !deliveredIDs.contains($0.eventID) }
        }
        let page = Array(unseen.prefix(limit))
        for item in page { deliveredIDs.insert(item.eventID) }
        let hasMore = !reachedStart || unseen.count > limit
        return MediaGalleryPage(items: page, hasMore: hasMore)
    }

    func close() async {
        guard !isClosed else { return }
        isClosed = true
        handle?.cancel()
        handle = nil
    }
}
