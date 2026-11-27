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

    /// The full content as a file in `directory` (which exists), named `name` (only its last path component is used), written to disk
    /// as it arrives and decrypted there, never held whole in memory (M19-5, FR-10). Returns the file's URL; the caller owns it.
    func file(_ ref: MediaRef, name: String, mimeType: String?, in directory: URL) async throws(HaloError) -> URL
}

public extension MediaPort {
    /// A safe file name from one a sender chose: its last path component, never empty, `.` or `..`.
    static func safeFileName(_ name: String) -> String {
        let last = name.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? ""
        return last.isEmpty || last == "." || last == ".." ? "file" : last
    }

    /// For ports that have no file API (fakes): the content in memory, written out.
    func file(_ ref: MediaRef, name: String, mimeType: String?, in directory: URL) async throws(HaloError) -> URL {
        let data = try await content(ref)
        let url = directory.appendingPathComponent(Self.safeFileName(name))
        do { try data.write(to: url, options: .atomic) } catch { throw .storage(.unavailable) }
        return url
    }
}

/// The account's media preview setting (`m.media_preview_config`, MEDIA_ATTACHMENTS FR-7): whether photos in a room are
/// shown at once or only after a tap. The adapter resolves "private rooms only" against the room, so callers get one answer.
public protocol MediaPreviewPolicyPort: Sendable {
    /// `true` when photos in `room` may be loaded and shown without a tap. An unreadable or unset policy means yes (the SDK default).
    func previewsAllowed(in room: RoomID) async -> Bool

    /// The stored setting, for the Settings screen; an unset or unreadable one is `.always`.
    func setting() async -> MediaPreviewSetting

    /// Stores the setting in the account data (`m.media_preview_config`), so every device follows it.
    func setSetting(_ setting: MediaPreviewSetting) async throws(HaloError)
}

/// The three values of the account's media preview setting.
public enum MediaPreviewSetting: Sendable, Equatable, CaseIterable {
    case always, privateRoomsOnly, never
}
