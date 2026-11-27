#if canImport(UIKit)
import Testing
import UIKit
@testable import HaloDesignSystem

@Suite("ImagePipeline (M19-1)")
struct ImagePipelineTests {
    private func png(width: Int, height: Int, shade: CGFloat = 0.5) -> Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: { let f = UIGraphicsImageRendererFormat(); f.scale = 1; return f }())
        return renderer.pngData { context in
            UIColor(white: shade, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    @Test("a big picture is shrunk to the size it is shown at, not decoded whole")
    func shrinks() async throws {
        ImagePipeline.evictAll()
        let decoded = try #require(await ImagePipeline.decode(png(width: 2000, height: 1000), maxPixel: 400))
        #expect(max(decoded.size.width * decoded.scale, decoded.size.height * decoded.scale) == 400)
        #expect(decoded.size.width > decoded.size.height, "the proportions stay")
    }

    @Test("a decoded picture is found again at once, per size; another picture or size is not")
    func caches() async throws {
        ImagePipeline.evictAll()
        let data = png(width: 800, height: 800)
        #expect(ImagePipeline.cached(data, maxPixel: 200) == nil)
        let first = try #require(await ImagePipeline.decode(data, maxPixel: 200))
        #expect(ImagePipeline.cached(data, maxPixel: 200) === first)
        #expect(ImagePipeline.cached(data, maxPixel: 400) == nil, "another size is another entry")
        #expect(ImagePipeline.cached(png(width: 800, height: 801), maxPixel: 200) == nil, "another picture is another entry")
    }

    @Test("evicting empties the cache; bytes that aren't a picture decode to nothing")
    func evicts() async throws {
        let data = png(width: 100, height: 100)
        _ = await ImagePipeline.decode(data, maxPixel: 100)
        ImagePipeline.evictAll()
        #expect(ImagePipeline.cached(data, maxPixel: 100) == nil)
        #expect(await ImagePipeline.decode(Data("not a picture".utf8), maxPixel: 100) == nil)
    }

    @Test("a small picture is not enlarged")
    func noEnlarging() async throws {
        let decoded = try #require(await ImagePipeline.decode(png(width: 50, height: 50), maxPixel: 900))
        #expect(decoded.size.width * decoded.scale <= 900)
    }

    @Test("decoding directly from a file URL shrinks off the main thread and caches per size (M19-5)")
    func decodesFromFileURL() async throws {
        ImagePipeline.evictAll()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("halo-pipe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("big.png")
        try png(width: 1600, height: 800).write(to: file)

        #expect(ImagePipeline.cached(fileURL: file, maxPixel: 400) == nil)
        let decoded = try #require(await ImagePipeline.decode(fileURL: file, maxPixel: 400))
        #expect(max(decoded.size.width * decoded.scale, decoded.size.height * decoded.scale) == 400)
        #expect(decoded.size.width > decoded.size.height)
        #expect(ImagePipeline.cached(fileURL: file, maxPixel: 400) === decoded)
        #expect(ImagePipeline.cached(fileURL: file, maxPixel: 800) == nil)
    }

    @Test("PagedPhotoViewer.removeTemporaryFolder deletes viewer and gallery temp folders while sparing unrelated paths")
    func temporaryFolderCleanup() throws {
        let fm = FileManager.default
        let prefixes = ["halo-viewer-", "halo-photo-", "halo-global-gallery-", "halo-gallery-"]
        for prefix in prefixes {
            let folder = fm.temporaryDirectory.appendingPathComponent("\(prefix)\(UUID().uuidString)", isDirectory: true)
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appendingPathComponent("item.jpg")
            try Data([1, 2, 3]).write(to: file)
            PagedPhotoViewer.removeTemporaryFolder(of: file)
            #expect(!fm.fileExists(atPath: folder.path), "expected \(prefix) folder to be removed")
        }

        let unrelated = fm.temporaryDirectory.appendingPathComponent("other-folder-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: unrelated, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: unrelated) }
        let kept = unrelated.appendingPathComponent("keep.jpg")
        try Data([4, 5]).write(to: kept)
        PagedPhotoViewer.removeTemporaryFolder(of: kept)
        #expect(fm.fileExists(atPath: kept.path), "unrelated folders must never be deleted")
    }
}
#endif
