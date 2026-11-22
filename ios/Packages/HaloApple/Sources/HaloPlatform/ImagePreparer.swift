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
    public let jpegQuality: Double

    public init(maximumDimension: Int = 2048, jpegQuality: Double = 0.85) {
        self.maximumDimension = maximumDimension
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
        let buffer = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(buffer, output.type.identifier as CFString, 1, nil) else { throw .internal(code: "IMAGE_ENCODE") }
        CGImageDestinationAddImage(destination, cgImage, [kCGImageDestinationLossyCompressionQuality: jpegQuality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw .internal(code: "IMAGE_ENCODE") }

        let image = OutgoingImage(data: buffer as Data, filename: Self.name(filename, ext: output.ext), mimeType: output.mime, width: cgImage.width, height: cgImage.height)
        try image.validate()
        return image
    }

    /// The file name with its extension replaced; a blank name becomes `image`.
    static func name(_ filename: String, ext: String) -> String {
        let stem = (filename as NSString).deletingPathExtension.trimmingCharacters(in: .whitespacesAndNewlines)
        return (stem.isEmpty ? "image" : stem) + "." + ext
    }
}
