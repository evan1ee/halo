import Foundation
import HaloFoundation

/// A file, audio or video clip ready to be uploaded and sent as it is (docs/features/MEDIA_ATTACHMENTS.md). Unlike an
/// `OutgoingImage` nothing is re-encoded: the bytes go to the server unchanged, so the sender is the one who decides what a
/// document or recording contains.
public struct OutgoingFile: Sendable, Equatable {
    /// What the homeserver accepts by default (Synapse `max_upload_size` is 50 MiB). The whole file is held in memory.
    public static let maximumBytes = 50 * 1024 * 1024

    public enum Kind: Sendable, Equatable { case file, audio, video }

    public let data: Data
    public let filename: String
    public let mimeType: String

    public init(data: Data, filename: String, mimeType: String) {
        self.data = data
        self.filename = filename
        self.mimeType = mimeType
    }

    /// `m.audio` and `m.video` for those media types, `m.file` for everything else.
    public var kind: Kind {
        if mimeType.hasPrefix("audio/") { return .audio }
        if mimeType.hasPrefix("video/") { return .video }
        return .file
    }

    /// Checks what every port requires: some data, a name that is a plain file name, a size under `maximumBytes`.
    public func validate() throws(HaloError) {
        guard !data.isEmpty else { throw .invalidInput("EMPTY_FILE") }
        guard data.count <= Self.maximumBytes else { throw .invalidInput("FILE_TOO_LARGE") }
        guard !filename.isEmpty, !filename.contains("/"), filename != ".", filename != ".." else { throw .invalidInput("FILE_NAME") }
    }
}
