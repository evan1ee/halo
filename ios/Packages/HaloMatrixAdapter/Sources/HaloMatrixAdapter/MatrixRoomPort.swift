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
        return RoomDetails(
            id: id, name: room.displayName(), topic: room.topic(), isDirect: direct, isEncrypted: encrypted,
            joinedMemberCount: Int(room.joinedMembersCount()), notificationMode: Self.choice(mode))
    }

    public func members(_ id: RoomID, limit: Int) async throws(HaloError) -> [RoomMemberInfo] {
        let room = try await session.room(id)
        let own = try await session.ownUserID()
        var result: [RoomMemberInfo] = []
        do {
            let iterator = try await room.members()
            while let chunk = iterator.nextChunk(chunkSize: 100) {
                for member in chunk where member.membership == .join || member.membership == .invite {
                    result.append(RoomMemberInfo(userID: member.userId, displayName: member.displayName, role: Self.role(member.suggestedRoleForPowerLevel), isInvited: member.membership == .invite, isMe: member.userId == own))
                }
                if result.count >= limit { break }
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

    public func acceptInvite(_ id: RoomID) async throws(HaloError) {
        let client = try await session.signedInClient()
        do { _ = try await client.joinRoomById(roomId: id.rawValue) } catch { throw ErrorMapper.map(error) }
    }

    public func declineInvite(_ id: RoomID) async throws(HaloError) {
        let room = try await session.room(id)
        do { try await room.leave() } catch { throw ErrorMapper.map(error) }
    }

    public func leave(_ id: RoomID) async throws(HaloError) {
        let room = try await session.room(id)
        do { try await room.leave() } catch { throw ErrorMapper.map(error) }
    }

    static func choice(_ mode: RoomNotificationMode) -> RoomNotificationChoice {
        switch mode { case .allMessages: .allMessages; case .mentionsAndKeywordsOnly: .mentionsAndKeywords; case .mute: .mute }
    }

    static func role(_ role: MatrixRustSDK.RoomMemberRole) -> HaloDomain.RoomMemberRole {
        switch role { case .creator, .administrator: .administrator; case .moderator: .moderator; case .user: .user }
    }
}
