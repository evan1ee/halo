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
    /// Duration in seconds for audio or video clips, when known.
    public let duration: TimeInterval?
    /// Normalised `[0, 1]` amplitude samples for voice messages (MSC1767).
    public let waveform: [Float]?
    /// `true` when recorded as a voice note (MSC3245 `org.matrix.msc3245.voice`).
    public let isVoiceMessage: Bool

    public init(
        data: Data, filename: String, mimeType: String,
        duration: TimeInterval? = nil, waveform: [Float]? = nil, isVoiceMessage: Bool = false
    ) {
        self.data = data
        self.filename = filename
        self.mimeType = mimeType
        self.duration = duration
        self.waveform = waveform
        self.isVoiceMessage = isVoiceMessage
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
