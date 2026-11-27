@preconcurrency import AVFoundation
import CoreGraphics
import Foundation
import HaloDomain
import HaloFoundation
import ImageIO
import UniformTypeIdentifiers

/// `VideoPreparing` over `AVFoundation` and `ImageIO` (MEDIA_ATTACHMENTS FR-2, D56, M20-3, M20-5).
///
/// Reads display-oriented dimensions (applying track rotation so portrait videos stay portrait), duration,
/// strips GPS/location metadata losslessly via passthrough export when present (D56), and creates a 600 px
/// JPEG poster frame without loading the video file into memory.
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
        let sourceAsset = AVURLAsset(url: fileURL)

        let cleanURL = try await stripLocationMetadataIfNeeded(
            from: sourceAsset, sourceURL: fileURL, safeName: safeName, mimeType: mimeType
        )
        let asset = cleanURL == fileURL ? sourceAsset : AVURLAsset(url: cleanURL)

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
            fileURL: cleanURL,
            width: pixelWidth,
            height: pixelHeight,
            caption: nil,
            thumbnail: thumbnail
        )
        try outgoing.validate()
        return outgoing
    }

    /// Returns `true` when the container carries any GPS/location metadata item (D56).
    public static func hasLocationMetadata(in asset: AVURLAsset) async -> Bool {
        let allItems = (try? await asset.load(.metadata)) ?? []  // best-effort: unreadable metadata treated as empty
        let commonItems = (try? await asset.load(.commonMetadata)) ?? []  // best-effort: unreadable metadata treated as empty
        let combined = allItems + commonItems
        if !AVMetadataItem.metadataItems(from: combined, filteredByIdentifier: .commonIdentifierLocation).isEmpty {
            return true
        }
        if !AVMetadataItem.metadataItems(from: combined, filteredByIdentifier: .quickTimeMetadataLocationISO6709).isEmpty {
            return true
        }
        if !AVMetadataItem.metadataItems(from: combined, filteredByIdentifier: .quickTimeUserDataLocationISO6709).isEmpty {
            return true
        }
        return combined.contains { item in
            let id = item.identifier?.rawValue.lowercased() ?? ""
            let key = item.commonKey?.rawValue.lowercased() ?? ""
            return id.contains("location") || id.contains("gps") || id.contains("xyz") || key.contains("location")
        }
    }

    /// Strips location metadata losslessly using `AVMetadataItemFilter.forSharing()` without re-encoding video frames (D56).
    /// Fails closed if location metadata is present and cannot be removed.
    private func stripLocationMetadataIfNeeded(
        from asset: AVURLAsset, sourceURL: URL, safeName: String, mimeType: String
    ) async throws(HaloError) -> URL {
        guard await Self.hasLocationMetadata(in: asset) else { return sourceURL }

        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            throw .internal(code: "VIDEO_METADATA_STRIP_FAILED")
        }

        let ext = (safeName as NSString).pathExtension.lowercased()
        let preferredType: AVFileType = (ext == "mov" || mimeType == "video/quicktime") ? .mov : .mp4
        let compatible = export.supportedFileTypes
        let outputType: AVFileType
        if compatible.contains(preferredType) {
            outputType = preferredType
        } else if compatible.contains(.mp4) {
            outputType = .mp4
        } else if compatible.contains(.mov) {
            outputType = .mov
        } else if let first = compatible.first {
            outputType = first
        } else {
            throw .internal(code: "VIDEO_METADATA_STRIP_FAILED")
        }

        let cleanDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("halo-pending-video-clean-\(UUID().uuidString)", isDirectory: true)
        let cleanURL = cleanDir.appendingPathComponent(safeName)
        do {
            try FileManager.default.createDirectory(at: cleanDir, withIntermediateDirectories: true)
        } catch {
            throw .internal(code: "VIDEO_METADATA_STRIP_FAILED")
        }

        export.metadataItemFilter = AVMetadataItemFilter.forSharing()
        do {
            try await export.export(to: cleanURL, as: outputType)
        } catch {
            try? FileManager.default.removeItem(at: cleanDir)
            throw .internal(code: "VIDEO_METADATA_STRIP_FAILED")
        }

        let cleanedAsset = AVURLAsset(url: cleanURL)
        if await Self.hasLocationMetadata(in: cleanedAsset) {
            try? FileManager.default.removeItem(at: cleanDir)
            throw .internal(code: "VIDEO_METADATA_STRIP_FAILED")
        }
        return cleanURL
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
