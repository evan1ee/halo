import Foundation
import HaloFoundation

/// An image ready to be uploaded and sent (docs/features/MEDIA_ATTACHMENTS.md). Built by an `ImagePreparing`
/// implementation, never by a view.
public struct OutgoingImage: Sendable, Equatable {
    public static let maximumBytes = 20 * 1024 * 1024

    /// Precomputed inline thumbnail uploaded alongside the photo so own thumbnails never need re-downloading after a restart (M19-5)
    /// and recipients in encrypted rooms don't have to download the full image just to render a bubble.
    public struct Thumbnail: Sendable, Equatable {
        public let data: Data
        public let mimeType: String
        public let width: Int
        public let height: Int

        public init(data: Data, mimeType: String, width: Int, height: Int) {
            self.data = data
            self.mimeType = mimeType
            self.width = width
            self.height = height
        }
    }

    public let data: Data
    public let filename: String
    public let mimeType: String
    public let width: Int?
    public let height: Int?
    public let caption: String?
    public let thumbnail: Thumbnail?

    public init(
        data: Data, filename: String, mimeType: String, width: Int?, height: Int?,
        caption: String? = nil, thumbnail: Thumbnail? = nil
    ) {
        self.data = data
        self.filename = filename
        self.mimeType = mimeType
        self.width = width
        self.height = height
        self.caption = caption
        self.thumbnail = thumbnail
    }

    /// Checks what every port requires: some data, an image type, a size under `maximumBytes`.
    public func validate() throws(HaloError) {
        guard !data.isEmpty else { throw .invalidInput("EMPTY_IMAGE") }
        guard mimeType.hasPrefix("image/") else { throw .invalidInput("NOT_AN_IMAGE") }
        guard data.count <= Self.maximumBytes else { throw .invalidInput("IMAGE_TOO_LARGE") }
    }

    public func with(caption: String?) -> OutgoingImage {
        OutgoingImage(
            data: data, filename: filename, mimeType: mimeType, width: width, height: height,
            caption: caption, thumbnail: thumbnail)
    }
}

/// Turns picked bytes into an `OutgoingImage`: checks that it is an image, reads its size, shrinks it and removes metadata
/// such as the location (privacy, AGENTS §4.6). Implemented by `HaloPlatform`.
public protocol ImagePreparing: Sendable {
    func prepare(data: Data, filename: String) throws(HaloError) -> OutgoingImage
}
