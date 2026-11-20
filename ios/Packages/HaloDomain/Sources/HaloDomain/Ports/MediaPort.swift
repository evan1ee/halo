import Foundation
import HaloFoundation

/// Media download (docs/matrix/MEDIA.md, PORTS_CONTRACT §2). Implemented by `HaloMatrixAdapter`; faked in
/// `HaloTestSupport`. M1: reading only; upload arrives with M2.
public protocol MediaPort: Sendable {
    /// A thumbnail of at most `width` × `height` points-in-pixels; the server may return a different size.
    /// Throws `.notFound` for media that no longer exists and `.network` while offline.
    func thumbnail(_ ref: MediaRef, width: Int, height: Int) async throws(HaloError) -> Data

    /// The full content. Large files use a file-based API in M2; this is for images shown inline.
    func content(_ ref: MediaRef) async throws(HaloError) -> Data
}

/// The account's media preview setting (`m.media_preview_config`, MEDIA_ATTACHMENTS FR-7): whether photos in a room are
/// shown at once or only after a tap. The adapter resolves "private rooms only" against the room, so callers get one answer.
public protocol MediaPreviewPolicyPort: Sendable {
    /// `true` when photos in `room` may be loaded and shown without a tap. An unreadable or unset policy means yes (the SDK default).
    func previewsAllowed(in room: RoomID) async -> Bool
}
