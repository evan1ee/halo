#if canImport(UIKit)
import ImageIO
import SwiftUI
import UIKit

/// Decoding and showing a sticker image, shared by the sticker panel and the timeline (STICKERS FR-5, FR-9). A multi-frame image (GIF, animated WebP/PNG) plays only when
/// motion is allowed: Reduce Motion and Low Power Mode both show the first frame.
public enum StickerImage {
    /// Frame limit: bounds memory for a long animation (512 px stickers are ~1 MB a frame decoded).
    public static let maxFrames = 60

    public static var motionAllowed: Bool { !UIAccessibility.isReduceMotionEnabled && !ProcessInfo.processInfo.isLowPowerModeEnabled }

    /// `true` for a GIF, APNG or WebP with more than one frame.
    public static func isAnimated(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return false }
        return CGImageSourceGetCount(source) > 1
    }

    /// The image for `data`: animated when `animated` and the data has several frames, else the first frame.
    public static func decode(_ data: Data, animated: Bool) -> UIImage? {
        guard animated, let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 1 else {
            return UIImage(data: data)
        }
        var frames: [UIImage] = []
        var duration = 0.0
        for index in 0..<min(CGImageSourceGetCount(source), maxFrames) {
            guard let frame = CGImageSourceCreateImageAtIndex(source, index, nil) else { continue }
            frames.append(UIImage(cgImage: frame))
            duration += delay(source, index)
        }
        guard frames.count > 1 else { return UIImage(data: data) }
        return UIImage.animatedImage(with: frames, duration: max(duration, 0.1))
    }

    private static func delay(_ source: CGImageSource, _ index: Int) -> Double {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] else { return 0.1 }
        for key in [kCGImagePropertyGIFDictionary, kCGImagePropertyPNGDictionary, kCGImagePropertyWebPDictionary] {
            guard let dictionary = properties[key] as? [CFString: Any] else { continue }
            let unclamped = (dictionary["UnclampedDelayTime" as CFString] as? Double) ?? 0
            let clamped = (dictionary["DelayTime" as CFString] as? Double) ?? 0
            let value = unclamped > 0 ? unclamped : clamped
            if value > 0 { return value }
        }
        return 0.1
    }
}

/// A `UIImageView` that animates a multi-frame `UIImage` by itself.
public struct AnimatedStickerView: UIViewRepresentable {
    let data: Data

    public init(data: Data) { self.data = data }

    public func makeUIView(context: Context) -> UIImageView {
        let view = UIImageView()
        view.contentMode = .scaleAspectFit
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        return view
    }

    public func updateUIView(_ view: UIImageView, context: Context) {
        view.image = StickerImage.decode(data, animated: StickerImage.motionAllowed)
    }
}
#endif
