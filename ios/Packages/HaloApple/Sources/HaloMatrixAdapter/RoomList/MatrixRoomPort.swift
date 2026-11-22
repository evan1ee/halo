import Foundation
import HaloDomain
import HaloFoundation
import MatrixRustSDK

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
        if let levels = try? await room.getPowerLevels(), let own = try? await session.ownUserID() {
            canEdit = (try? levels.canUserSendState(userId: own, stateEvent: .roomName)) == true && (try? levels.canUserSendState(userId: own, stateEvent: .roomTopic)) == true
            canInvite = (try? levels.canUserInvite(userId: own)) == true
        }
        return RoomDetails(
            id: id, name: room.displayName(), topic: room.topic(), isDirect: direct, isEncrypted: encrypted,
            joinedMemberCount: Int(room.joinedMembersCount()), notificationMode: Self.choice(mode), canEditDetails: canEdit, canInvite: canInvite,
            avatar: MatrixRoomListPort.avatar(room.avatarUrl()))
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

    public func mediaGallery(in id: RoomID, limit: Int) async throws(HaloError) -> [RoomMediaItem] {
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
            let (raw, continuation) = AsyncStream<[MatrixRustSDK.TimelineDiff]>.makeStream(bufferingPolicy: .unbounded)
            let handle = await timeline.addListener(listener: GalleryListener(continuation))
            defer { handle.cancel(); continuation.finish() }

            // Paginate backwards until we have enough media items or reach the start of the room (bounded to 5 pages).
            let paginateTask = Task {
                for _ in 0..<5 {
                    let reachedStart = (try? await timeline.paginateBackwards(numEvents: 40)) ?? true
                    if reachedStart { break }
                }
                continuation.finish()
            }
            defer { paginateTask.cancel() }

            var items: [HaloDomain.TimelineItem] = []
            for await batch in raw {
                for update in batch {
                    let mapped = TimelineMapper.map(update, ownUserID: own)
                    try? ListReducer.apply(mapped, to: &items)
                }
                if items.count >= limit { break }
            }
            var media: [RoomMediaItem] = []
            for item in items.reversed() {
                guard case .event(let event) = item.content,
                      let eventID = event.eventID,
                      case .media(let attachment) = event.kind else { continue }
                media.append(RoomMediaItem(
                    eventID: eventID,
                    senderName: event.senderName ?? event.sender?.rawValue ?? "Unknown",
                    timestamp: event.timestamp,
                    attachment: attachment))
                if media.count >= limit { break }
            }
            return media
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
            reportUtds: true)
        do {
            let timeline = try await room.timelineWithConfiguration(configuration: config)
            let (raw, continuation) = AsyncStream<[MatrixRustSDK.TimelineDiff]>.makeStream(bufferingPolicy: .unbounded)
            let handle = await timeline.addListener(listener: GalleryListener(continuation))
            defer { handle.cancel(); continuation.finish() }

            let paginateTask = Task {
                for _ in 0..<10 {
                    let reachedStart = (try? await timeline.paginateBackwards(numEvents: 50)) ?? true
                    if reachedStart { break }
                }
                continuation.finish()
            }
            defer { paginateTask.cancel() }

            var items: [HaloDomain.TimelineItem] = []
            for await batch in raw {
                for update in batch {
                    let mapped = TimelineMapper.map(update, ownUserID: own)
                    try? ListReducer.apply(mapped, to: &items)
                }
                if items.count >= limit { break }
            }
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
        case .sticker(let body, _):
            return RoomExportMessage(eventID: eventID.rawValue, senderID: senderID, senderName: senderName, timestamp: event.timestamp, kind: "sticker", body: body)
        case .location(let body, let geoURI):
            return RoomExportMessage(eventID: eventID.rawValue, senderID: senderID, senderName: senderName, timestamp: event.timestamp, kind: "location", body: "\(body) (\(geoURI))")
        case .poll(let question, _, _):
            return RoomExportMessage(eventID: eventID.rawValue, senderID: senderID, senderName: senderName, timestamp: event.timestamp, kind: "poll", body: question)
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
