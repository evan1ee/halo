#if canImport(SwiftUI) && canImport(CoreGraphics)
import CoreGraphics
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Renders a tiny decoded RGBA8 pixel buffer (such as a BlurHash placeholder) as a scaled SwiftUI `Image` (MEDIA_ATTACHMENTS FR-1).
public struct RGBAPlaceholderImage: View {
    private let width: Int
    private let height: Int
    private let rgba: [UInt8]

    public init(width: Int, height: Int, rgba: [UInt8]) {
        self.width = width
        self.height = height
        self.rgba = rgba
    }

    public var body: some View {
        if let cgImage = Self.makeCGImage(width: width, height: height, rgba: rgba) {
            #if canImport(UIKit)
            Image(uiImage: UIImage(cgImage: cgImage))
                .resizable()
                .scaledToFill()
            #else
            Image(decorative: cgImage, scale: 1)
                .resizable()
                .scaledToFill()
            #endif
        } else {
            Rectangle().fill(.secondary.opacity(0.2))
        }
    }

    private static func makeCGImage(width: Int, height: Int, rgba: [UInt8]) -> CGImage? {
        guard width > 0, height > 0, rgba.count == width * height * 4 else { return nil }
        let data = Data(rgba)
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
    }
}
#endif
