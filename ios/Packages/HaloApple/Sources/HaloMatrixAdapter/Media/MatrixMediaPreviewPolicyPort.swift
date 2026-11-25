import Foundation
import HaloDomain
import HaloFoundation
import MatrixRustSDK

/// `MediaPreviewPolicyPort` over the account data of MSC4278: `m.media_preview_config` (stable) and
/// `io.element.msc4278.media_preview_config` (unstable), content `{ "media_previews": "on" | "private" | "off" }`, plus
/// `Room.isPublic` for the "private rooms only" value (MEDIA_ATTACHMENTS FR-7, F-FFI-18).
///
/// Read and written directly rather than through the SDK's `get/setMediaPreviewDisplayPolicy`: found against infra/dev, the SDK
/// writes only the unstable type but reads the stable one, so a value it just set never reads back. Both types are written
/// (other clients read either), the stable one wins on reading, and other keys of the content (`invite_avatars`) are kept.
public final class MatrixMediaPreviewPolicyPort: MediaPreviewPolicyPort {
    private static let stableType = "m.media_preview_config"
    private static let unstableType = "io.element.msc4278.media_preview_config"
    private let session: MatrixSessionPort

    public init(session: MatrixSessionPort) { self.session = session }

    public func setting() async -> MediaPreviewSetting {
        guard let client = try? await session.signedInClient() else { return .always }
        return await Self.read(client)
    }

    public func setSetting(_ setting: MediaPreviewSetting) async throws(HaloError) {
        let client = try await session.signedInClient()
        let value = switch setting { case .always: "on"; case .privateRoomsOnly: "private"; case .never: "off" }
        do {
            for type in [Self.stableType, Self.unstableType] {
                try await ServerAccountData(client).update(type) { current in
                    var content = current ?? [:]
                    content["media_previews"] = value
                    return content
                }
            }
        } catch { throw ErrorMapper.map(error) }
    }

    public func previewsAllowed(in room: RoomID) async -> Bool {
        guard let client = try? await session.signedInClient() else { return true }
        switch await Self.read(client) {
        case .always: return true
        case .never: return false
        case .privateRoomsOnly:
            // Public rooms are the ones to protect; a room whose join rule is unknown counts as public (the careful reading).
            guard let sdkRoom = try? await session.room(room) else { return false }
            return sdkRoom.isPublic() == false
        }
    }

    private static func read(_ client: Client) async -> MediaPreviewSetting {
        for type in [stableType, unstableType] {
            guard let json = try? await client.accountData(eventType: type), let value = object(json)?["media_previews"] as? String else { continue }
            switch value {
            case "off": return .never
            case "private": return .privateRoomsOnly
            case "on": return .always
            default: continue
            }
        }
        return .always
    }

    private static func object(_ json: String) -> [String: Any]? { try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] }
}
