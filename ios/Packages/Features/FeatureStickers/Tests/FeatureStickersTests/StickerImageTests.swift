#if canImport(UIKit)
import ImageIO
import Testing
import UIKit
import UniformTypeIdentifiers

@testable import FeatureStickers

@Suite("StickerImage")
struct StickerImageTests {
    private func gif(frames: Int) throws -> Data {
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.gif.identifier as CFString, frames, nil))
        let fileProperties = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary
        CGImageDestinationSetProperties(destination, fileProperties)
        for index in 0..<frames {
            let renderer = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8))
            let image = renderer.image { context in
                UIColor(hue: CGFloat(index) / CGFloat(max(frames, 1)), saturation: 1, brightness: 1, alpha: 1).setFill()
                context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
            }
            let frameProperties = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.2]] as CFDictionary
            CGImageDestinationAddImage(destination, try #require(image.cgImage), frameProperties)
        }
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    @Test("an animated image plays all its frames when animation is allowed")
    func animated() throws {
        let image = try #require(StickerImage.decode(try gif(frames: 3), animated: true))
        #expect(image.images?.count == 3)
        #expect(abs(image.duration - 0.6) < 0.01)
    }

    @Test("with Reduce Motion or Low Power Mode the first frame is shown")
    func staticFirstFrame() throws {
        let image = try #require(StickerImage.decode(try gif(frames: 3), animated: false))
        #expect(image.images == nil)
    }

    @Test("a single-frame image is not animated")
    func single() throws {
        let image = try #require(StickerImage.decode(try gif(frames: 1), animated: true))
        #expect(image.images == nil)
    }

    @Test("data that isn't an image gives nil")
    func garbage() { #expect(StickerImage.decode(Data([1, 2, 3]), animated: true) == nil) }
}
#endif
