#if canImport(UIKit)
import ImageIO
import SwiftUI
import UIKit

/// An image (animated GIF/WebP/APNG or still) loaded on demand and decoded off the main thread at display size, for the
/// GIF and sticker grids and KLIPY messages in the timeline (docs/features/COMPOSER_PANELS.md §6).
///
/// Frames are decoded as thumbnails no larger than `maxPixelSize`, so a grid of animations stays within a few MB each.
/// Reduce Motion and Low Power Mode show the first frame (STICKERS FR-9).
public struct AsyncAnimatedImage<Placeholder: View>: View {
    private let id: String
    private let maxPixelSize: Int
    private let load: @Sendable () async -> Data?
    private let placeholder: Placeholder
    private let fills: Bool
    @State private var image: UIImage?

    /// - Parameters:
    ///   - id: identifies the source; a new id reloads.
    ///   - maxPixelSize: the longest side frames are decoded at (use the view's size × screen scale).
    ///   - fills: fills and crops the frame (grid tiles) instead of fitting inside it.
    public init(id: String, maxPixelSize: Int, fills: Bool = false, load: @escaping @Sendable () async -> Data?, @ViewBuilder placeholder: () -> Placeholder) {
        self.id = id
        self.fills = fills
        self.maxPixelSize = maxPixelSize
        self.load = load
        self.placeholder = placeholder()
    }

    public var body: some View {
        ZStack {
            if let image {
                AnimatedImageView(image: image, fills: fills).allowsHitTesting(false)
            } else {
                placeholder
            }
        }
        .task(id: id) {
            image = nil
            let animated = StickerImage.motionAllowed
            guard let data = await load(), !Task.isCancelled else { return }
            let decoded = await StickerImage.decodeThumbnail(data, maxPixelSize: maxPixelSize, animated: animated)
            guard !Task.isCancelled else { return }
            image = decoded
        }
    }
}

extension StickerImage {
    /// Frame limit for grid thumbnails (lower than `maxFrames`: many play at once).
    public static let maxThumbnailFrames = 40

    /// Decodes `data` as display-size frames off the main actor; animated when `animated` and there are several frames.
    @concurrent public static func decodeThumbnail(_ data: Data, maxPixelSize: Int, animated: Bool) async -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let count = CGImageSourceGetCount(source)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixelSize),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard animated, count > 1 else {
            return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary).map { UIImage(cgImage: $0) }
        }
        // Long animations are sampled evenly so they keep their speed within the frame limit.
        let step = max(1, Int((Double(count) / Double(maxThumbnailFrames)).rounded(.up)))
        var frames: [UIImage] = []
        var duration = 0.0
        var index = 0
        while index < count {
            if let frame = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary) { frames.append(UIImage(cgImage: frame)) }
            for skipped in index..<min(index + step, count) { duration += frameDelay(source, skipped) }
            index += step
        }
        guard frames.count > 1 else { return frames.first }
        return UIImage.animatedImage(with: frames, duration: max(duration, 0.1))
    }

    static func frameDelay(_ source: CGImageSource, _ index: Int) -> Double {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] else { return 0.1 }
        for key in [kCGImagePropertyGIFDictionary, kCGImagePropertyPNGDictionary, kCGImagePropertyWebPDictionary] {
            guard let dictionary = properties[key] as? [CFString: Any] else { continue }
            let unclamped = (dictionary["UnclampedDelayTime" as CFString] as? Double) ?? 0
            let clamped = (dictionary["DelayTime" as CFString] as? Double) ?? 0
            let value = unclamped > 0.011 ? unclamped : clamped
            if value > 0.011 { return value }
        }
        return 0.1
    }
}

/// A `UIImageView` showing an already decoded (possibly animated) image, fitting its frame.
public struct AnimatedImageView: UIViewRepresentable {
    let image: UIImage
    let fills: Bool

    public init(image: UIImage, fills: Bool = false) {
        self.image = image
        self.fills = fills
    }

    public func makeUIView(context: Context) -> UIImageView {
        let view = UIImageView()
        view.clipsToBounds = true
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentHuggingPriority(.defaultLow, for: .vertical)
        return view
    }

    public func updateUIView(_ view: UIImageView, context: Context) {
        view.contentMode = fills ? .scaleAspectFill : .scaleAspectFit
        if view.image !== image { view.image = image }
        if image.images != nil, !view.isAnimating { view.startAnimating() }
    }
}
#endif
