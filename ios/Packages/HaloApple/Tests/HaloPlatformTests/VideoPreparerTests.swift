@preconcurrency import AVFoundation
import CoreGraphics
import CoreVideo
import Foundation
import HaloDomain
import HaloFoundation
import Testing
@testable import HaloPlatform

@Suite("VideoPreparer (M20-3)")
struct VideoPreparerTests {
    /// Writes a tiny real H.264 `.mp4` with the given raw dimensions and track transform (for testing portrait rotation).
    private func makeMP4(width: Int, height: Int, transform: CGAffineTransform = .identity) async throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("halo-vidprep-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("sample.mp4")

        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.transform = transform
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ]
        )
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        let frameTimes = [CMTime(value: 0, timescale: 30), CMTime(value: 15, timescale: 30), CMTime(value: 30, timescale: 30)]
        for time in frameTimes {
            var pixelBuffer: CVPixelBuffer?
            let status = CVPixelBufferCreate(
                kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, nil, &pixelBuffer)
            guard status == kCVReturnSuccess, let buffer = pixelBuffer else {
                throw HaloError.internal(code: "PIXEL_BUFFER")
            }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let base = CVPixelBufferGetBaseAddress(buffer) {
                memset(base, 0x80, CVPixelBufferGetBytesPerRow(buffer) * height)
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            while !input.isReadyForMoreMediaData { await Task.yield() }
            adaptor.append(buffer, withPresentationTime: time)
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw writer.error ?? HaloError.internal(code: "WRITER_FAILED")
        }
        return url
    }

    @Test("prepares landscape and 90-degree rotated portrait videos with oriented dimensions, duration, and JPEG poster")
    func preparesLandscapeAndPortraitVideos() async throws {
        let preparer = VideoPreparer()

        let landscapeURL = try await makeMP4(width: 320, height: 180)
        defer { try? FileManager.default.removeItem(at: landscapeURL.deletingLastPathComponent()) }
        let landscape = try await preparer.prepare(fileURL: landscapeURL, filename: "land.mp4", mimeType: "video/mp4")
        #expect(landscape.kind == .video)
        #expect(landscape.data.isEmpty)
        #expect(landscape.fileURL == landscapeURL)
        #expect(landscape.width == 320 && landscape.height == 180)
        #expect((landscape.duration ?? 0) > 0.5)
        let landThumb = try #require(landscape.thumbnail)
        #expect(landThumb.mimeType == "image/jpeg" && !landThumb.data.isEmpty)
        #expect(landThumb.width > landThumb.height)

        // Portrait video encoded as 320×180 with 90° rotation transform → display size 180×320!
        let portraitURL = try await makeMP4(width: 320, height: 180, transform: CGAffineTransform(rotationAngle: .pi / 2))
        defer { try? FileManager.default.removeItem(at: portraitURL.deletingLastPathComponent()) }
        let portrait = try await preparer.prepare(fileURL: portraitURL, filename: "port.mp4", mimeType: "video/mp4")
        #expect(portrait.width == 180 && portrait.height == 320)
        let portThumb = try #require(portrait.thumbnail)
        #expect(portThumb.height > portThumb.width)
    }

    @Test("rejects empty video file")
    func rejectsEmptyFile() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("halo-vidempty-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let empty = dir.appendingPathComponent("empty.mp4")
        try Data().write(to: empty)

        await #expect(throws: HaloError.invalidInput("EMPTY_FILE")) {
            _ = try await VideoPreparer().prepare(fileURL: empty, filename: "empty.mp4", mimeType: "video/mp4")
        }
    }
}
