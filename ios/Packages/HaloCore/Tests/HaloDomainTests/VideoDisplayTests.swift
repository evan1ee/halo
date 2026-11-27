import Foundation
import HaloDomain
import HaloFoundation
import Testing

@Suite("Video display & outgoing video domain helpers")
struct VideoDisplayTests {
    @Test("Aspect ratio preserves portrait 9:16 and landscape 16:9 while clamping extremes")
    func aspectRatios() {
        let portrait = VideoDisplayMetrics.aspectRatio(width: 1080, height: 1920)
        #expect(abs(portrait - 0.5625) < 0.001)

        let landscape = VideoDisplayMetrics.aspectRatio(width: 1920, height: 1080)
        #expect(abs(landscape - (16.0 / 9.0)) < 0.001)

        let square = VideoDisplayMetrics.aspectRatio(width: 720, height: 720)
        #expect(square == 1.0)

        #expect(VideoDisplayMetrics.aspectRatio(width: nil, height: nil) == VideoDisplayMetrics.defaultAspectRatio)
        #expect(VideoDisplayMetrics.aspectRatio(width: 100, height: 1000) == VideoDisplayMetrics.minimumAspectRatio)
        #expect(VideoDisplayMetrics.aspectRatio(width: 4000, height: 500) == VideoDisplayMetrics.maximumAspectRatio)
    }

    @Test("Caption resolution prefers explicit caption and ignores bare filenames")
    func captionResolution() {
        #expect(VideoDisplayMetrics.caption(body: "clip.mp4", explicitCaption: nil) == nil)
        #expect(VideoDisplayMetrics.caption(body: "IMG_1234.MOV", explicitCaption: "   ") == nil)
        #expect(VideoDisplayMetrics.caption(body: "clip.mp4", explicitCaption: "Sunset at the beach") == "Sunset at the beach")
        #expect(VideoDisplayMetrics.caption(body: "Look at this wave!", explicitCaption: nil) == "Look at this wave!")
    }

    @Test("Video filename sanitises traversal and infers extension from MIME type")
    func videoFilenameInference() {
        #expect(VideoDisplayMetrics.videoFilename(from: "clip.mp4", mimeType: "video/mp4") == "clip.mp4")
        #expect(VideoDisplayMetrics.videoFilename(from: "movie.mov", mimeType: "video/quicktime") == "movie.mov")
        #expect(VideoDisplayMetrics.videoFilename(from: "Sunset clip", mimeType: "video/quicktime") == "Sunset clip.mov")
        #expect(VideoDisplayMetrics.videoFilename(from: "Video", mimeType: "video/mp4; codecs=avc1") == "Video.mp4")
        #expect(VideoDisplayMetrics.videoFilename(from: "../escape", mimeType: nil) == "escape.mp4")
    }

    @Test("File-backed OutgoingFile validates disk size without loading data into memory and attaches caption")
    func fileBackedOutgoingVideo() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("halo-video-domain-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = dir.appendingPathComponent("clip.mp4")
        try Data(repeating: 0x42, count: 128).write(to: url)

        let thumb = OutgoingImage.Thumbnail(data: Data([1, 2, 3]), mimeType: "image/jpeg", width: 320, height: 180)
        let video = OutgoingFile(
            filename: "clip.mp4", mimeType: "video/mp4", duration: 12.5,
            fileURL: url, width: 1280, height: 720, caption: nil, thumbnail: thumb
        ).with(caption: "  Demo clip  ")

        try video.validate()
        #expect(video.kind == .video)
        #expect(video.data.isEmpty)
        #expect(video.byteCount == 128)
        #expect(video.caption == "Demo clip")
        #expect(video.width == 1280 && video.height == 720 && video.duration == 12.5)
        #expect(video.thumbnail == thumb)

        let emptyURL = dir.appendingPathComponent("empty.mp4")
        try Data().write(to: emptyURL)
        let empty = OutgoingFile(filename: "empty.mp4", mimeType: "video/mp4", fileURL: emptyURL)
        #expect(throws: HaloError.invalidInput("EMPTY_FILE")) { try empty.validate() }
    }
}
