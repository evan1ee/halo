@preconcurrency import AVFoundation
import CoreGraphics
import Foundation
import HaloDomain
import HaloFoundation
import ImageIO
import UniformTypeIdentifiers

/// `VideoPreparing` over `AVFoundation` and `ImageIO` (MEDIA_ATTACHMENTS FR-2, M20-3).
///
/// Reads display-oriented dimensions (applying track rotation so portrait videos stay portrait), duration,
/// and a 600 px JPEG poster frame without loading the video file into memory.
public struct VideoPreparer: VideoPreparing {
    public let thumbnailDimension: Int
    public let jpegQuality: Double

    public init(thumbnailDimension: Int = 600, jpegQuality: Double = 0.8) {
        self.thumbnailDimension = thumbnailDimension
        self.jpegQuality = jpegQuality
    }

    public func prepare(fileURL: URL, filename: String, mimeType: String) async throws(HaloError) -> OutgoingFile {
        let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size > 0 else { throw .invalidInput("EMPTY_FILE") }
        guard size <= OutgoingFile.maximumBytes else { throw .invalidInput("FILE_TOO_LARGE") }

        let safeName = VideoDisplayMetrics.videoFilename(from: filename, mimeType: mimeType)
        let asset = AVURLAsset(url: fileURL)

        let rawDuration = try? await asset.load(.duration)  // best-effort: duration is optional metadata
        let durationSeconds: TimeInterval? = rawDuration.flatMap { cmTime in
            let s = CMTimeGetSeconds(cmTime)
            return s.isFinite && s > 0 ? s : nil
        }

        var pixelWidth: Int?
        var pixelHeight: Int?
        if let track = try? await asset.loadTracks(withMediaType: .video).first,  // best-effort: dimensions are optional metadata
           let naturalSize = try? await track.load(.naturalSize),  // best-effort: dimensions are optional metadata
           let transform = try? await track.load(.preferredTransform) {  // best-effort: orientation defaults to identity
            let oriented = CGRect(origin: .zero, size: naturalSize).applying(transform)
            let w = Int(abs(oriented.width).rounded())
            let h = Int(abs(oriented.height).rounded())
            if w > 0, h > 0 {
                pixelWidth = w
                pixelHeight = h
            }
        }

        let thumbnail = await generatePoster(for: asset)
        let outgoing = OutgoingFile(
            data: Data(),
            filename: safeName,
            mimeType: mimeType,
            duration: durationSeconds,
            fileURL: fileURL,
            width: pixelWidth,
            height: pixelHeight,
            caption: nil,
            thumbnail: thumbnail
        )
        try outgoing.validate()
        return outgoing
    }

    private func generatePoster(for asset: AVURLAsset) async -> OutgoingImage.Thumbnail? {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: thumbnailDimension, height: thumbnailDimension)
        guard let cgImage = try? await generator.image(at: .zero).image else { return nil }  // best-effort: videos still send without a poster frame
        guard let data = encodeJPEG(cgImage) else { return nil }
        return OutgoingImage.Thumbnail(data: data, mimeType: "image/jpeg", width: cgImage.width, height: cgImage.height)
    }

    private func encodeJPEG(_ cgImage: CGImage) -> Data? {
        let buffer = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(buffer, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, cgImage, [kCGImageDestinationLossyCompressionQuality: jpegQuality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return buffer as Data
    }
}
