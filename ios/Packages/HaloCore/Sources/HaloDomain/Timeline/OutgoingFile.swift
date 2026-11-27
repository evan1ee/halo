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
    /// Optional local file on disk (e.g. a staged video clip) so uploads stream from disk without holding the full file in RAM (M19-5, M20-3).
    public let fileURL: URL?
    public let filename: String
    public let mimeType: String
    /// Duration in seconds for audio or video clips, when known.
    public let duration: TimeInterval?
    /// Pixel dimensions (display-oriented, after rotation transform) for videos, when known.
    public let width: Int?
    public let height: Int?
    /// Optional caption sent with a video clip (M20-3).
    public let caption: String?
    /// Precomputed poster thumbnail for a video clip, when available (M20-3).
    public let thumbnail: OutgoingImage.Thumbnail?
    /// Normalised `[0, 1]` amplitude samples for voice messages (MSC1767).
    public let waveform: [Float]?
    /// `true` when recorded as a voice note (MSC3245 `org.matrix.msc3245.voice`).
    public let isVoiceMessage: Bool

    public init(
        data: Data = Data(), filename: String, mimeType: String,
        duration: TimeInterval? = nil, waveform: [Float]? = nil, isVoiceMessage: Bool = false,
        fileURL: URL? = nil, width: Int? = nil, height: Int? = nil,
        caption: String? = nil, thumbnail: OutgoingImage.Thumbnail? = nil
    ) {
        self.data = data
        self.fileURL = fileURL
        self.filename = filename
        self.mimeType = mimeType
        self.duration = duration
        self.width = width
        self.height = height
        self.caption = caption
        self.thumbnail = thumbnail
        self.waveform = waveform
        self.isVoiceMessage = isVoiceMessage
    }

    /// Returns a copy with an optional caption attached (blank captions become `nil`).
    public func with(caption: String?) -> OutgoingFile {
        let trimmed = caption?.trimmingCharacters(in: .whitespacesAndNewlines)
        return OutgoingFile(
            data: data, filename: filename, mimeType: mimeType,
            duration: duration, waveform: waveform, isVoiceMessage: isVoiceMessage,
            fileURL: fileURL, width: width, height: height,
            caption: trimmed?.isEmpty == true ? nil : trimmed, thumbnail: thumbnail)
    }

    /// Byte count of `data`, or the disk file size when backed by `fileURL`.
    public var byteCount: Int {
        if let fileURL {
            return (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        }
        return data.count
    }

    /// `m.audio` and `m.video` for those media types, `m.file` for everything else.
    public var kind: Kind {
        if mimeType.hasPrefix("audio/") { return .audio }
        if mimeType.hasPrefix("video/") { return .video }
        return .file
    }

    /// Checks what every port requires: some data (or non-empty file on disk), a plain file name, and a size under `maximumBytes`.
    public func validate() throws(HaloError) {
        let count = byteCount
        guard count > 0 else { throw .invalidInput("EMPTY_FILE") }
        guard count <= Self.maximumBytes else { throw .invalidInput("FILE_TOO_LARGE") }
        guard !filename.isEmpty, !filename.contains("/"), filename != ".", filename != ".." else { throw .invalidInput("FILE_NAME") }
    }
}
