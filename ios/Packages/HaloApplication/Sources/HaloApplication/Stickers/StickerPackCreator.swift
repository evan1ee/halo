import Foundation
import HaloDomain
import HaloFoundation

/// Makes a personal sticker pack from picked photos (STICKERS FR-7): shrinks each image to the sticker size (D52), gives it a
/// valid, unique shortcode, and hands the result to the creation port.
public actor StickerPackCreator {
    /// Images over this size after shrinking are refused (STICKERS §11).
    public static let maximumImageBytes = 5 * 1024 * 1024

    /// A picked photo with the shortcode it will get.
    public struct Picked: Sendable, Equatable {
        public let data: Data
        public let filename: String
        public var shortcode: String

        public init(data: Data, filename: String, shortcode: String) {
            self.data = data
            self.filename = filename
            self.shortcode = shortcode
        }
    }

    private let port: any StickerPackCreationPort
    private let preparer: any ImagePreparing

    /// - Parameter preparer: shrinks to 512 px (`HaloPlatform.ImagePreparer(maximumDimension: 512)`).
    public init(port: any StickerPackCreationPort, preparer: any ImagePreparing) {
        self.port = port
        self.preparer = preparer
    }

    /// The shortcode for a new photo: from its file name, unique among `taken`.
    public static func shortcode(forFilename filename: String, avoiding taken: Set<String>) -> String {
        ShortcodeRules.unique(ShortcodeRules.make(fromFilename: filename), avoiding: taken)
    }

    /// Creates the pack. Throws `.invalidInput` (see `ImagePackBuilder.validate`, `NOT_AN_IMAGE`, `IMAGE_TOO_LARGE`) before
    /// anything is uploaded; upload and server errors as they come.
    public func create(name: String, pictures: [Picked], progress: @escaping @Sendable (Int, Int) -> Void) async throws(HaloError) -> PackRef {
        try ImagePackBuilder.validate(name: name, shortcodes: pictures.map(\.shortcode))
        var images: [NewStickerImage] = []
        for picture in pictures {
            let prepared = try preparer.prepare(data: picture.data, filename: picture.filename)
            guard prepared.data.count <= Self.maximumImageBytes else { throw .invalidInput("IMAGE_TOO_LARGE") }
            images.append(NewStickerImage(
                data: prepared.data, mimeType: prepared.mimeType, width: prepared.width, height: prepared.height, shortcode: picture.shortcode))
        }
        return try await port.createPack(name: name, images: images, progress: progress)
    }
}
