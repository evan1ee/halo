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
}
#endif
