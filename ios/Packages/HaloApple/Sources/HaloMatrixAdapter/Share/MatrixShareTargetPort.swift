import Foundation
import HaloDomain
import HaloFoundation
import MatrixRustSDK

/// `ShareTargetPort` over the SDK's local room store (M16, D92). Reads the rooms the app last synced; it never syncs, so it
/// works in the share extension, which must not start `SyncService` (AGENTS §17).
public final class MatrixShareTargetPort: ShareTargetPort {
    private let session: MatrixSessionPort

    public init(session: MatrixSessionPort) { self.session = session }

    public func targets() async throws(HaloError) -> [ShareTarget] {
        let client = try await session.signedInClient()
        var targets: [ShareTarget] = []
        for room in client.rooms() where room.membership() == .joined {
            guard let info = try? await room.roomInfo(), !info.isSpace, info.successorRoom == nil else { continue }
            let name = (info.displayName ?? room.displayName() ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, let id = try? RoomID(room.id()) else { continue }
            let latest = MatrixRoomListPort.latestEvent(await room.latestEvent())
            targets.append(ShareTarget(id: id, name: name, isDirect: info.isDirect, isFavourite: info.isFavourite, lastActivity: latest?.timestamp))
        }
        return ShareTarget.ordered(targets)
    }
}
