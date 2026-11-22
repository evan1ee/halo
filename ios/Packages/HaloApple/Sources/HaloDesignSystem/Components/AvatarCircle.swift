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

#if canImport(SwiftUI)
import SwiftUI

/// A round avatar: the image when `imageData` decodes, otherwise the initial of `name` in a stable soft tint.
/// Loading the bytes is the caller's job.
public struct AvatarCircle: View {
    private static let palette: [Color] = [.blue, .teal, .pink, .orange, .green, .mint]

    private let name: String
    private let imageData: Data?
    private let size: CGFloat

    public init(name: String, imageData: Data?, size: CGFloat = 44) {
        self.name = name
        self.imageData = imageData
        self.size = size
    }

    private var tint: Color {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "?" else { return .secondary }
        return Self.palette[avatarColorIndex(for: trimmed, count: Self.palette.count)]
    }

    public var body: some View {
        ZStack {
            if let image = Self.image(imageData) {
                Circle().fill(.quaternary)
                image.resizable().scaledToFill()
            } else {
                Circle().fill(tint.opacity(0.18))
                Text(avatarInitial(for: name))
                    .font(.system(size: size * 0.4, weight: .semibold, design: .rounded))
                    .foregroundStyle(tint)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
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
#endif
