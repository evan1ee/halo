import CoreGraphics
import Foundation
import HaloDomain
import HaloFoundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import HaloPlatform

@Suite("FileShareInbox")
struct FileShareInboxTests {
    private func makeDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("share-inbox-\(UUID().uuidString)", isDirectory: true)
    }

    private func jpeg(_ width: Int, _ height: Int, gps: Bool = false) -> Data {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(red: 0.2, green: 0.4, blue: 0.9, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let buffer = NSMutableData()
        let destination = CGImageDestinationCreateWithData(buffer, UTType.jpeg.identifier as CFString, 1, nil)!
        let properties: [CFString: Any] = gps ? [kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 51.5, kCGImagePropertyGPSLongitude: -0.12]] : [:]
        CGImageDestinationAddImage(destination, context.makeImage()!, properties as CFDictionary)
        CGImageDestinationFinalize(destination)
        return buffer as Data
    }

    @Test("a photo is prepared: its pixel size is recorded, location metadata is dropped, an unreadable image becomes a file")
    func preparesPhotos() throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let inbox = FileShareInbox(directory: directory)
        let staged = try inbox.stage([
            .file(data: jpeg(120, 60, gps: true), filename: "IMG_1.HEIC", mimeType: "image/heic", isImage: true),
            .file(data: Data("not an image".utf8), filename: "x.jpg", mimeType: "image/jpeg", isImage: true),
        ])
        let photo = try #require(staged.items.first)
        #expect(photo.kind == .image && photo.width == 120 && photo.height == 60)
        #expect(photo.filename == "IMG_1.jpg" && photo.mimeType == "image/jpeg")
        let bytes = try inbox.data(of: photo, in: staged)
        let properties = CGImageSourceCreateWithData(bytes as CFData, nil).flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [CFString: Any] }
        #expect(properties?[kCGImagePropertyGPSDictionary] == nil)
        #expect(staged.items.last?.kind == .file)
    }

    @Test("staged items round-trip through pending() and data(of:)")
    func roundTrip() throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let inbox = FileShareInbox(directory: directory)
        let staged = try inbox.stage([
            .text("hello"), .url("https://example.org"),
            .file(data: Data([1, 2, 3]), filename: "../evil/photo.jpg", mimeType: "image/jpeg", isImage: false),
        ])
        let pending = try inbox.pending()
        #expect(pending == [staged])
        let photo = try #require(pending.first?.items.last)
        #expect(photo.kind == .file && photo.filename == "photo.jpg" && photo.byteCount == 3)
        #expect(try inbox.data(of: photo, in: staged) == Data([1, 2, 3]))
        inbox.discard(staged)
        #expect(try inbox.pending().isEmpty)
    }

    @Test("an empty or oversized share is refused and leaves nothing behind")
    func refusals() throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let inbox = FileShareInbox(directory: directory)
        #expect(throws: HaloError.invalidInput("SHARE_EMPTY")) { try inbox.stage([]) }
        let big = Data(count: FileShareInbox.maximumPayloadBytes + 1)
        #expect(throws: HaloError.invalidInput("SHARE_TOO_LARGE")) {
            try inbox.stage([.file(data: big, filename: "x", mimeType: "application/octet-stream", isImage: false)])
        }
        #expect(try inbox.pending().isEmpty)
    }

    @Test("expired payloads are deleted when listed; newer ones stay, oldest first")
    func expiry() throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = Clock(Date(timeIntervalSince1970: 1_000_000))
        let inbox = FileShareInbox(directory: directory, now: { clock.value })
        let old = try inbox.stage([.text("old")])
        clock.value = clock.value.addingTimeInterval(SharePayload.lifetime - 10)
        let first = try inbox.stage([.text("first")])
        clock.value = clock.value.addingTimeInterval(5)
        let second = try inbox.stage([.text("second")])
        clock.value = clock.value.addingTimeInterval(20)  // `old` is now past its lifetime
        #expect(try inbox.pending() == [first, second])
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent(old.id).path))
    }

    @Test("a damaged payload folder is removed instead of failing the listing")
    func damaged() throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let inbox = FileShareInbox(directory: directory)
        let good = try inbox.stage([.text("ok")])
        let broken = directory.appendingPathComponent("broken", isDirectory: true)
        try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
        #expect(try inbox.pending() == [good])
        #expect(!FileManager.default.fileExists(atPath: broken.path))
    }

    @Test("an item that isn't in the payload can't be read")
    func foreignItem() throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let inbox = FileShareInbox(directory: directory)
        let staged = try inbox.stage([.text("x")])
        let stranger = SharedItem(kind: .file, filename: "f")
        #expect(throws: HaloError.notFound) { try inbox.data(of: stranger, in: staged) }
    }
}

private final class Clock: @unchecked Sendable {  // test-only mutable clock, used from one thread
    var value: Date
    init(_ value: Date) { self.value = value }
}
