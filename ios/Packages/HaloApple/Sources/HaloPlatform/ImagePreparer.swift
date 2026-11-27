import Foundation
import HaloDomain
import HaloFoundation
import ImageIO
import UniformTypeIdentifiers

/// `ImagePreparing` over ImageIO. Photos are decoded with their orientation applied, shrunk to `maximumDimension` and
/// re-encoded, which drops EXIF/GPS metadata (AGENTS §4.6). Animated GIFs are sent as they are (re-encoding would flatten
/// them) when small enough. Anything ImageIO can't read as an image is refused.
public struct ImagePreparer: ImagePreparing {
    public let maximumDimension: Int
    public let thumbnailDimension: Int
    public let jpegQuality: Double

    public init(maximumDimension: Int = 2048, thumbnailDimension: Int = 600, jpegQuality: Double = 0.85) {
        self.maximumDimension = maximumDimension
        self.thumbnailDimension = thumbnailDimension
        self.jpegQuality = jpegQuality
    }

    public func prepare(data: Data, filename: String) throws(HaloError) -> OutgoingImage {
        guard !data.isEmpty else { throw .invalidInput("EMPTY_IMAGE") }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0,
              let typeID = CGImageSourceGetType(source), let type = UTType(typeID as String), type.conforms(to: .image)
        else { throw .invalidInput("NOT_AN_IMAGE") }

        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let pixelWidth = properties?[kCGImagePropertyPixelWidth] as? Int
        let pixelHeight = properties?[kCGImagePropertyPixelHeight] as? Int

        // Animated GIF: keep the bytes.
        if type == .gif, CGImageSourceGetCount(source) > 1 {
            let image = OutgoingImage(data: data, filename: Self.name(filename, ext: "gif"), mimeType: "image/gif", width: pixelWidth, height: pixelHeight)
            try image.validate()
            return image
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,  // applies the EXIF orientation
            kCGImageSourceThumbnailMaxPixelSize: maximumDimension,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { throw .invalidInput("NOT_AN_IMAGE") }

        // Keep transparency (PNG) where there is any; everything else becomes JPEG.
        let hasAlpha: Bool = { switch cgImage.alphaInfo { case .none, .noneSkipFirst, .noneSkipLast: false; default: true } }()
        let output: (type: UTType, mime: String, ext: String) = hasAlpha ? (.png, "image/png", "png") : (.jpeg, "image/jpeg", "jpg")
        let encoded = try encode(cgImage, type: output.type, quality: jpegQuality)

        // Generate a precomputed inline thumbnail for larger photos (M19-5): cached locally by the SDK on upload and
        // downloaded cheaply by recipients in encrypted rooms.
        var thumbnail: OutgoingImage.Thumbnail?
        if max(cgImage.width, cgImage.height) > thumbnailDimension {
            let thumbOptions: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: thumbnailDimension,
            ]
            if let thumbCG = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions as CFDictionary),
               let thumbData = try? encode(thumbCG, type: output.type, quality: min(jpegQuality, 0.8)) {
                thumbnail = OutgoingImage.Thumbnail(data: thumbData, mimeType: output.mime, width: thumbCG.width, height: thumbCG.height)
            }
        }

        let image = OutgoingImage(
            data: encoded, filename: Self.name(filename, ext: output.ext), mimeType: output.mime,
            width: cgImage.width, height: cgImage.height, thumbnail: thumbnail)
        try image.validate()
        return image
    }

    private func encode(_ cgImage: CGImage, type: UTType, quality: Double) throws(HaloError) -> Data {
        let buffer = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(buffer, type.identifier as CFString, 1, nil) else { throw .internal(code: "IMAGE_ENCODE") }
        CGImageDestinationAddImage(destination, cgImage, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw .internal(code: "IMAGE_ENCODE") }
        return buffer as Data
    }

    /// The file name with its extension replaced; a blank name becomes `image`.
    static func name(_ filename: String, ext: String) -> String {
        let stem = (filename as NSString).deletingPathExtension.trimmingCharacters(in: .whitespacesAndNewlines)
        return (stem.isEmpty ? "image" : stem) + "." + ext
    }
}
