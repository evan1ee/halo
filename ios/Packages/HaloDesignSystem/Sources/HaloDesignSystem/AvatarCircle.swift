import Foundation

/// The letter an avatar shows when there is no image: the first letter of the name, else its first character, else "?".
public func avatarInitial(for name: String) -> String {
    let trimmed = name.trimmingCharacters(in: CharacterSet(charactersIn: "@#!"))
    return String(trimmed.first(where: \.isLetter) ?? trimmed.first ?? "?").uppercased()
}

#if canImport(SwiftUI)
import SwiftUI

/// A round avatar: the image when `imageData` decodes, otherwise the initial of `name`. Loading the bytes is the caller's job.
public struct AvatarCircle: View {
    private let name: String
    private let imageData: Data?
    private let size: CGFloat

    public init(name: String, imageData: Data?, size: CGFloat = 44) {
        self.name = name
        self.imageData = imageData
        self.size = size
    }

    public var body: some View {
        ZStack {
            Circle().fill(.quaternary)
            if let image = Self.image(imageData) {
                image.resizable().scaledToFill()
            } else {
                Text(avatarInitial(for: name)).font(.system(size: size * 0.4, weight: .semibold)).foregroundStyle(.secondary)
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
