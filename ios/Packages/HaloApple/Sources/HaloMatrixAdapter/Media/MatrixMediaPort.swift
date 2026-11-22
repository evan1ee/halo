import Foundation
import HaloDomain
import HaloFoundation

/// `MediaPort` over the SDK client's media API (docs/matrix/MEDIA.md). Decryption of encrypted media happens inside the SDK.
public final class MatrixMediaPort: MediaPort {
    private let session: MatrixSessionPort

    public init(session: MatrixSessionPort) { self.session = session }

    public func thumbnail(_ ref: MediaRef, width: Int, height: Int) async throws(HaloError) -> Data {
        try await session.mediaData(ref, thumbnail: (width, height))
    }

    public func content(_ ref: MediaRef) async throws(HaloError) -> Data {
        try await session.mediaData(ref, thumbnail: nil)
    }
}
