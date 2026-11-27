import Foundation
import HaloFoundation
import SwiftUI
#if canImport(UIKit)
import ImageIO
import UIKit
#endif

/// The one way a picture gets from bytes to pixels (ROADMAP M19-1, NFR-12/13): decoded off the main thread, shrunk to the size it is
/// shown at, kept in a cache with a cost cap and emptied on a memory warning. No view decodes a picture itself (lint `image_pipeline`).
public enum ImagePipeline {
    /// Sizes in pixels for the places pictures are shown (3× the points of the biggest case).
    public enum Size {
        public static let timeline = 960
        public static let gridCell = 420
        public static let listRow = 180
        public static let sticker = 360
        public static let viewer = 3072
        public static func avatar(points: CGFloat) -> Int { max(24, Int((points * 3).rounded(.up))) }
    }

    /// The memory the decoded pictures may take together.
    public static let costLimit = 64 * 1024 * 1024

    /// Where a picture is kept: its bytes (count, start and end) and the pixel size it was decoded for.
    static func key(_ data: Data, maxPixel: Int) -> String {
        var hasher = Hasher()
        hasher.combine(data.count)
        hasher.combine(data.prefix(512))
        hasher.combine(data.suffix(512))
        return "\(hasher.finalize())-\(maxPixel)"
    }

    /// Cache key for a picture decoded straight from disk (M19-5): path, byte size, modification time and pixel size.
    static func fileKey(_ url: URL, maxPixel: Int) -> String {
        var hasher = Hasher()
        let path = url.standardizedFileURL.path
        hasher.combine(path)
        if let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) {
            hasher.combine(values.fileSize)
            hasher.combine(values.contentModificationDate?.timeIntervalSinceReferenceDate)
        }
        return "file-\(hasher.finalize())-\(maxPixel)"
    }

    #if canImport(UIKit)
    /// `NSCache` is thread-safe; the wrapper says so to the compiler and empties it on a memory warning.
    private final class Store: @unchecked Sendable {
        let cache = NSCache<NSString, UIImage>()
        private var observer: (any NSObjectProtocol)?
        init() {
            cache.totalCostLimit = ImagePipeline.costLimit
            cache.name = "halo.decoded-images"
            observer = NotificationCenter.default.addObserver(
                forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: nil) { [weak self] _ in self?.clear() }
        }
        func clear() { cache.removeAllObjects() }
    }

    private static let store = Store()
    private static var cache: NSCache<NSString, UIImage> { store.cache }

    /// The picture if it was decoded before; cheap enough for a view's first frame.
    public static func cached(_ data: Data, maxPixel: Int) -> UIImage? {
        return cache.object(forKey: key(data, maxPixel: maxPixel) as NSString)
    }

    /// The picture if this file was decoded before at `maxPixel`.
    public static func cached(fileURL: URL, maxPixel: Int) -> UIImage? {
        return cache.object(forKey: fileKey(fileURL, maxPixel: maxPixel) as NSString)
    }

    /// Decodes off the main thread, at most `maxPixel` on the long side, orientation applied, and keeps the result.
    @concurrent public static func decode(_ data: Data, maxPixel: Int) async -> UIImage? {
        if let hit = cached(data, maxPixel: maxPixel) { return hit }
        guard let image = HaloSignpost.measure(.imageDecode, { thumbnail(data, maxPixel: maxPixel) }) else { return nil }
        store(image, for: key(data, maxPixel: maxPixel))
        return image
    }

    /// Decodes directly from a file on disk off the main thread, never loading the full encoded bytes into memory (M19-5).
    @concurrent public static func decode(fileURL: URL, maxPixel: Int) async -> UIImage? {
        if let hit = cached(fileURL: fileURL, maxPixel: maxPixel) { return hit }
        guard let image = HaloSignpost.measure(.imageDecode, { thumbnail(fileURL: fileURL, maxPixel: maxPixel) }) else { return nil }
        store(image, for: fileKey(fileURL, maxPixel: maxPixel))
        return image
    }

    static func thumbnail(_ data: Data, maxPixel: Int) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return thumbnail(source: source, maxPixel: maxPixel)
    }

    static func thumbnail(fileURL: URL, maxPixel: Int) -> UIImage? {
        guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil) else { return nil }
        return thumbnail(source: source, maxPixel: maxPixel)
    }

    private static func thumbnail(source: CGImageSource, maxPixel: Int) -> UIImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixel),
            kCGImageSourceShouldCacheImmediately: true,  // decoded here, not on the main thread at first draw
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary).map { UIImage(cgImage: $0) }
    }

    private static func store(_ image: UIImage, for key: String) {
        let cost = Int(image.size.width * image.scale * image.size.height * image.scale) * 4
        cache.setObject(image, forKey: key as NSString, cost: cost)
    }

    /// Empties the cache (a memory warning does the same).
    public static func evictAll() { cache.removeAllObjects() }
    #endif
}

/// A picture from bytes, shown at once when it was decoded before, otherwise after a decode off the main thread.
public struct DecodedImage<Content: View, Placeholder: View>: View {
    private let data: Data?
    private let maxPixel: Int
    private let content: (Image) -> Content
    private let placeholder: () -> Placeholder
    #if canImport(UIKit)
    @State private var image: UIImage?
    #endif

    public init(
        _ data: Data?, maxPixel: Int,
        @ViewBuilder content: @escaping (Image) -> Content, @ViewBuilder placeholder: @escaping () -> Placeholder
    ) {
        self.data = data
        self.maxPixel = maxPixel
        self.content = content
        self.placeholder = placeholder
        #if canImport(UIKit)
        _image = State(initialValue: data.flatMap { ImagePipeline.cached($0, maxPixel: maxPixel) })
        #endif
    }

    public var body: some View {
        #if canImport(UIKit)
        Group {
            if let image { content(Image(uiImage: image)) } else { placeholder() }
        }
        .task(id: data.map { ImagePipeline.key($0, maxPixel: maxPixel) }) {
            guard let data else { image = nil; return }
            if let hit = ImagePipeline.cached(data, maxPixel: maxPixel) { image = hit; return }
            image = await ImagePipeline.decode(data, maxPixel: maxPixel)
        }
        #else
        placeholder()
        #endif
    }
}
