import Foundation
import HaloDomain
import HaloFoundation
import MatrixRustSDK

/// `NotificationDefaultsPort` over the client's `NotificationSettings` (default room notification mode per chat type).
public final class MatrixNotificationDefaultsPort: NotificationDefaultsPort {
    private let session: MatrixSessionPort

    public init(session: MatrixSessionPort) { self.session = session }

    public func mode(for kind: NotificationDefaultKind) async throws(HaloError) -> RoomNotificationChoice {
        let client = try await session.signedInClient()
        let settings = await client.getNotificationSettings()
        return MatrixRoomPort.choice(await settings.getDefaultRoomNotificationMode(isEncrypted: false, isOneToOne: kind == .directChats))
    }

    public func setMode(_ mode: RoomNotificationChoice, for kind: NotificationDefaultKind) async throws(HaloError) {
        let client = try await session.signedInClient()
        let settings = await client.getNotificationSettings()
        let sdkMode: RoomNotificationMode = switch mode { case .allMessages: .allMessages; case .mentionsAndKeywords: .mentionsAndKeywordsOnly; case .mute: .mute }
        do {
            for encrypted in [false, true] {
                try await settings.setDefaultRoomNotificationMode(isEncrypted: encrypted, isOneToOne: kind == .directChats, mode: sdkMode)
            }
        } catch { throw ErrorMapper.map(error) }
    }

    public func isMentionEnabled(_ kind: NotificationMentionKind) async throws(HaloError) -> Bool {
        let client = try await session.signedInClient()
        let settings = await client.getNotificationSettings()
        do { return kind == .user ? try await settings.isUserMentionEnabled() : try await settings.isRoomMentionEnabled() } catch { throw ErrorMapper.map(error) }
    }

    public func setMention(_ kind: NotificationMentionKind, enabled: Bool) async throws(HaloError) {
        let client = try await session.signedInClient()
        let settings = await client.getNotificationSettings()
        do {
            if kind == .user { try await settings.setUserMentionEnabled(enabled: enabled) } else { try await settings.setRoomMentionEnabled(enabled: enabled) }
        } catch { throw ErrorMapper.map(error) }
    }
}
