import HaloDomain
import HaloFoundation
import MatrixRustSDK

/// `MediaPreviewPolicyPort` over `Client.getMediaPreviewDisplayPolicy` (served from the SDK's store, which sync keeps current;
/// MEDIA_ATTACHMENTS FR-7, F-FFI-18) and `Room.isPublic`.
public final class MatrixMediaPreviewPolicyPort: MediaPreviewPolicyPort {
    private let session: MatrixSessionPort

    public init(session: MatrixSessionPort) { self.session = session }

    public func previewsAllowed(in room: RoomID) async -> Bool {
        guard let client = try? await session.signedInClient(),
              let policy = try? await client.getMediaPreviewDisplayPolicy() else { return true }
        switch policy {
        case .on: return true
        case .off: return false
        case .private:
            // Public rooms are the ones to protect; a room whose join rule is unknown counts as public (the careful reading).
            guard let sdkRoom = try? await session.room(room) else { return false }
            return sdkRoom.isPublic() == false
        }
    }
}
