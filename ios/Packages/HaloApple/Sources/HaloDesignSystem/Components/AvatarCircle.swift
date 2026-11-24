import Foundation

/// The letter an avatar shows when there is no image: the first letter of the name, else its first character, else "?".
public func avatarInitial(for name: String) -> String {
    let trimmed = name.trimmingCharacters(in: CharacterSet(charactersIn: "@#!"))
    return String(trimmed.first(where: \.isLetter) ?? trimmed.first ?? "?").uppercased()
}

/// Stable palette slot in `0..<count` for `name` (FNV-1a), so an avatar keeps the same tint across launches.
public func avatarColorIndex(for name: String, count: Int) -> Int {
    guard count > 0 else { return 0 }
    var hash: UInt64 = 14_695_981_039_346_656_037
    for byte in name.utf8 {
        hash ^= UInt64(byte)
        hash &*= 1_099_511_628_211
    }
    return Int(hash % UInt64(count))
}

/// The colours of a letter avatar, in sRGB components 0...1. The background is the hue washed out over the light or dark
/// row colour, and the letter is the hue darkened (light) or lightened (dark) so it reads at WCAG AA against it
/// (the system tints themselves at 18 % behind the same tint failed the accessibility audit, e.g. green "S" on pale green).
public enum AvatarTint {
    public struct RGB: Equatable, Sendable {
        public let r: Double
        public let g: Double
        public let b: Double
    }

    /// iOS system blue, teal, pink, orange, green and mint (light-mode values); grey for a name with no letter.
    public static let hues: [RGB] = [
        RGB(r: 0 / 255, g: 122 / 255, b: 255 / 255),
        RGB(r: 48 / 255, g: 176 / 255, b: 199 / 255),
        RGB(r: 255 / 255, g: 45 / 255, b: 85 / 255),
        RGB(r: 255 / 255, g: 149 / 255, b: 0 / 255),
        RGB(r: 52 / 255, g: 199 / 255, b: 89 / 255),
        RGB(r: 0 / 255, g: 199 / 255, b: 190 / 255),
    ]
    public static let neutral = RGB(r: 142 / 255, g: 142 / 255, b: 147 / 255)

    private static let lightRow = RGB(r: 1, g: 1, b: 1)
    private static let darkRow = RGB(r: 28 / 255, g: 28 / 255, b: 30 / 255)

    public static func background(_ hue: RGB, dark: Bool) -> RGB {
        blend(hue, over: dark ? darkRow : lightRow, amount: dark ? 0.3 : 0.18)
    }

    public static func letter(_ hue: RGB, dark: Bool) -> RGB {
        dark ? blend(lightRow, over: hue, amount: 0.45) : blend(RGB(r: 0, g: 0, b: 0), over: hue, amount: 0.5)
    }

    /// The hue for `name`: a stable palette slot, or grey when there is nothing to take a letter from.
    public static func hue(for name: String) -> RGB {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "?" else { return neutral }
        return hues[avatarColorIndex(for: trimmed, count: hues.count)]
    }

    private static func blend(_ top: RGB, over bottom: RGB, amount: Double) -> RGB {
        RGB(
            r: bottom.r + (top.r - bottom.r) * amount,
            g: bottom.g + (top.g - bottom.g) * amount,
            b: bottom.b + (top.b - bottom.b) * amount
        )
    }
}

#if canImport(SwiftUI)
import SwiftUI

/// A round avatar with an optional circular outer frame and inner ring: shows the image when `imageData` decodes,
/// otherwise the initial of `name` in a stable soft tint. Loading the bytes is the caller's job.
public struct AvatarCircle: View {
    private let name: String
    private let imageData: Data?
    private let size: CGFloat
    private let showsOuterFrame: Bool
    private let avatarBorderColor: Color?
    @Environment(\.colorScheme) private var colorScheme

    public init(
        name: String,
        imageData: Data?,
        size: CGFloat = 44,
        showsOuterFrame: Bool = true,
        avatarBorderColor: Color? = nil
    ) {
        self.name = name
        self.imageData = imageData
        self.size = size
        self.showsOuterFrame = showsOuterFrame
        self.avatarBorderColor = avatarBorderColor
    }

    /// Thickness of the circular ring between the outer circle border and the inner avatar circle.
    public static func ringInset(for size: CGFloat) -> CGFloat {
        max(1.5, (size * 0.10).rounded(.toNearestOrAwayFromZero))
    }

    /// Diameter of the inner clipped avatar circle inside the circular frame.
    public static func innerDiameter(for size: CGFloat) -> CGFloat {
        max(1, size - ringInset(for: size) * 2)
    }

    /// Stroke width of the outer circular border.
    public static func borderWidth(for size: CGFloat) -> CGFloat {
        max(0.75, min(1.5, size * 0.02))
    }

    private func color(_ rgb: AvatarTint.RGB) -> Color {
        Color(.sRGB, red: rgb.r, green: rgb.g, blue: rgb.b)
    }

    @ViewBuilder
    private func avatarContent(diameter: CGFloat) -> some View {
        ZStack {
            if let image = Self.image(imageData) {
                Circle().fill(.quaternary)
                image.resizable().scaledToFill()
            } else {
                let hue = AvatarTint.hue(for: name)
                let dark = colorScheme == .dark
                Circle().fill(color(AvatarTint.background(hue, dark: dark)))
                Text(avatarInitial(for: name))
                    .font(.system(size: diameter * 0.42, weight: .semibold, design: .rounded))
                    .foregroundStyle(color(AvatarTint.letter(hue, dark: dark)))
            }
        }
        .frame(width: diameter, height: diameter)
        .clipShape(Circle())
        .overlay {
            if let avatarBorderColor {
                Circle()
                    .strokeBorder(avatarBorderColor, lineWidth: 2)
            }
        }
    }

    public var body: some View {
        Group {
            if showsOuterFrame {
                ZStack {
                    Circle()
                        .fill(HaloColor.bgElevated)
                    avatarContent(diameter: Self.innerDiameter(for: size))
                }
                .frame(width: size, height: size)
                .clipShape(Circle())
                .overlay(
                    Circle()
                        .strokeBorder(
                            HaloColor.textSecondary.opacity(colorScheme == .dark ? 0.42 : 0.26),
                            lineWidth: Self.borderWidth(for: size)
                        )
                )
            } else {
                avatarContent(diameter: size)
            }
        }
        .accessibilityHidden(true)
    }

    private static func image(_ data: Data?) -> Image? {
        #if canImport(UIKit)
        guard let data, let ui = UIImage(data: data) else { return nil }
        return Image(uiImage: ui)
        #else
        return nil
        #endif
    }
}

#Preview("AvatarCircle — Light") {
    HStack(spacing: HaloSpacing.m) {
        AvatarCircle(name: "Alice", imageData: nil, size: 30)
        AvatarCircle(name: "Moments", imageData: nil, size: 52)
        AvatarCircle(name: "Food", imageData: nil, size: 80)
    }
    .padding()
}

#Preview("AvatarCircle — Dark") {
    HStack(spacing: HaloSpacing.m) {
        AvatarCircle(name: "Alice", imageData: nil, size: 30)
        AvatarCircle(name: "Moments", imageData: nil, size: 52)
        AvatarCircle(name: "Food", imageData: nil, size: 80)
    }
    .padding()
    .preferredColorScheme(.dark)
}
#endif
