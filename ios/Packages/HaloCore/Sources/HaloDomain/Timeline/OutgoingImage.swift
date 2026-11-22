import Foundation
import HaloFoundation

/// An image ready to be uploaded and sent (docs/features/MEDIA_ATTACHMENTS.md). Built by an `ImagePreparing`
/// implementation, never by a view.
public struct OutgoingImage: Sendable, Equatable {
    public static let maximumBytes = 20 * 1024 * 1024

    public let data: Data
    public let filename: String
    public let mimeType: String
    public let width: Int?
    public let height: Int?
    public let caption: String?

    public init(data: Data, filename: String, mimeType: String, width: Int?, height: Int?, caption: String? = nil) {
        self.data = data
        self.filename = filename
        self.mimeType = mimeType
        self.width = width
        self.height = height
        self.caption = caption
    }

    /// Checks what every port requires: some data, an image type, a size under `maximumBytes`.
    public func validate() throws(HaloError) {
        guard !data.isEmpty else { throw .invalidInput("EMPTY_IMAGE") }
        guard mimeType.hasPrefix("image/") else { throw .invalidInput("NOT_AN_IMAGE") }
        guard data.count <= Self.maximumBytes else { throw .invalidInput("IMAGE_TOO_LARGE") }
    }

    public func with(caption: String?) -> OutgoingImage {
        OutgoingImage(data: data, filename: filename, mimeType: mimeType, width: width, height: height, caption: caption)
    }
}

/// Turns picked bytes into an `OutgoingImage`: checks that it is an image, reads its size, shrinks it and removes metadata
/// such as the location (privacy, AGENTS §4.6). Implemented by `HaloPlatform`.
public protocol ImagePreparing: Sendable {
    func prepare(data: Data, filename: String) throws(HaloError) -> OutgoingImage
}
