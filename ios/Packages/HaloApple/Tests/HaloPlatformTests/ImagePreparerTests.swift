import CoreGraphics
import Foundation
import HaloDomain
import HaloFoundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import HaloPlatform

@Suite("ImagePreparer")
struct ImagePreparerTests {
    /// A solid-colour image encoded as `type`, optionally with an EXIF orientation and GPS metadata.
    private func make(_ width: Int, _ height: Int, type: UTType = .jpeg, alpha: Bool = false, orientation: Int? = nil, gps: Bool = false) -> Data {
        let info: CGImageAlphaInfo = alpha ? .premultipliedLast : .noneSkipLast
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info.rawValue)!
        context.setFillColor(red: 0.2, green: 0.4, blue: 0.9, alpha: alpha ? 0.5 : 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = context.makeImage()!
        let buffer = NSMutableData()
        let destination = CGImageDestinationCreateWithData(buffer, type.identifier as CFString, 1, nil)!
        var properties: [CFString: Any] = [:]
        if let orientation { properties[kCGImagePropertyOrientation] = orientation }
        if gps { properties[kCGImagePropertyGPSDictionary] = [kCGImagePropertyGPSLatitude: 51.5, kCGImagePropertyGPSLongitude: -0.12] }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        CGImageDestinationFinalize(destination)
        return buffer as Data
    }

    private func properties(_ data: Data) -> [CFString: Any]? {
        CGImageSourceCreateWithData(data as CFData, nil).flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [CFString: Any] }
    }

    @Test("a large photo is shrunk to the limit, keeps its aspect ratio and becomes a JPEG")
    func shrinks() throws {
        let out = try ImagePreparer(maximumDimension: 400).prepare(data: make(1200, 600), filename: "holiday.HEIC")
        #expect(out.mimeType == "image/jpeg" && out.filename == "holiday.jpg")
        #expect(out.width == 400 && out.height == 200)
        #expect(properties(out.data)?[kCGImagePropertyPixelWidth] as? Int == 400)
    }

    @Test("location metadata is removed")
    func stripsGPS() throws {
        let source = make(300, 300, gps: true)
        #expect(properties(source)?[kCGImagePropertyGPSDictionary] != nil)
        let out = try ImagePreparer().prepare(data: source, filename: "a.jpg")
        #expect(properties(out.data)?[kCGImagePropertyGPSDictionary] == nil)
    }

    @Test("the EXIF orientation is applied to the pixels, so a rotated photo reports its upright size")
    func orientation() throws {
        let out = try ImagePreparer().prepare(data: make(300, 100, orientation: 6), filename: "r.jpg")  // rotated 90°
        #expect(out.width == 100 && out.height == 300)
    }

    @Test("transparency keeps PNG; a small image is not enlarged")
    func png() throws {
        let out = try ImagePreparer().prepare(data: make(64, 64, type: .png, alpha: true), filename: "icon")
        #expect(out.mimeType == "image/png" && out.filename == "icon.png" && out.width == 64 && out.height == 64)
    }

    @Test("not an image, or empty, is refused")
    func refuses() {
        #expect(throws: HaloError.invalidInput("NOT_AN_IMAGE")) { try ImagePreparer().prepare(data: Data("hello".utf8), filename: "x.txt") }
        #expect(throws: HaloError.invalidInput("EMPTY_IMAGE")) { try ImagePreparer().prepare(data: Data(), filename: "x.png") }
    }

    @Test("file names get the right extension and a fallback")
    func names() {
        #expect(ImagePreparer.name("", ext: "jpg") == "image.jpg")
        #expect(ImagePreparer.name("a.b.png", ext: "jpg") == "a.b.jpg")
    }
}
