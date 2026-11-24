import SwiftUI

/// Standard room list row (`docs/design/DESIGN_SYSTEM.md` §7).
public struct RoomRow<AvatarContent: View>: View {
    private let name: String
    private let preview: String?
    private let timestamp: String?
    private let hasUnread: Bool
    private let isMuted: Bool
    private let isFavourite: Bool
    private let indicator: UnreadIndicator.Style
    private let previewIdentifier: String?
    private let avatar: AvatarContent

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    public init(
        name: String,
        preview: String? = nil,
        timestamp: String? = nil,
        hasUnread: Bool = false,
        isMuted: Bool = false,
        isFavourite: Bool = false,
        indicator: UnreadIndicator.Style = .none,
        previewIdentifier: String? = nil,
        @ViewBuilder avatar: () -> AvatarContent
    ) {
        self.name = name
        self.preview = preview
        self.timestamp = timestamp
        self.hasUnread = hasUnread
        self.isMuted = isMuted
        self.isFavourite = isFavourite
        self.indicator = indicator
        self.previewIdentifier = previewIdentifier
        self.avatar = avatar()
    }

    /// Combined VoiceOver label for a room row (`DESIGN_SYSTEM.md` §9).
    public static func accessibilitySummary(
        name: String,
        preview: String?,
        timestamp: String?,
        isMuted: Bool,
        isFavourite: Bool,
        indicator: UnreadIndicator.Style
    ) -> String {
        var parts: [String] = [name]
        if isFavourite { parts.append("Favourite") }
        if isMuted { parts.append("Muted") }
        switch indicator {
        case .none:
            break
        case .dot, .approximate:
            parts.append("unread messages")
        case .count(let n):
            parts.append(n == 1 ? "1 unread message" : "\(n) unread messages")
        case .mentions(let n):
            parts.append(n == 1 ? "1 mention" : "\(n) mentions")
        }
        if let preview, !preview.isEmpty {
            parts.append("last message \(preview)")
        }
        if let timestamp, !timestamp.isEmpty {
            parts.append(timestamp)
        }
        return parts.joined(separator: ", ")
    }

    /// Splits a leading sender prefix such as `"You:"` or `"shirdn:"` from the preview body so it can be emphasized.
    public static func splitPreviewPrefix(_ text: String) -> (prefix: String, body: String)? {
        guard let range = text.range(of: ": ") else { return nil }
        let prefixWithoutColon = text[..<range.lowerBound]
        guard !prefixWithoutColon.isEmpty,
              prefixWithoutColon.count <= 40,
              !prefixWithoutColon.contains("\n"),
              !prefixWithoutColon.contains("://")
        else { return nil }
        let colonEnd = text.index(after: range.lowerBound)
        return (String(text[..<colonEnd]), String(text[colonEnd...]))
    }

    public var body: some View {
        HStack(alignment: .top, spacing: HaloSpacing.m) {
            avatar
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: HaloSpacing.xs) {
                if dynamicTypeSize.isAccessibilitySize {
                    titleRow
                    HStack(spacing: HaloSpacing.xs) {
                        timestampText
                        UnreadIndicator(indicator)
                    }
                    if let preview {
                        previewText(preview)
                    }
                } else {
                    HStack(alignment: .firstTextBaseline, spacing: HaloSpacing.xs) {
                        titleRow
                        Spacer(minLength: HaloSpacing.xs)
                        timestampText
                    }
                    if preview != nil || indicator != .none {
                        HStack(alignment: .top, spacing: HaloSpacing.xs) {
                            if let preview {
                                previewText(preview)
                            }
                            if indicator != .none {
                                Spacer(minLength: HaloSpacing.xs)
                                UnreadIndicator(indicator)
                            }
                        }
                    }
                }
            }
            .alignmentGuide(.listRowSeparatorLeading) { dimensions in
                dimensions[.leading]
            }
        }
        .padding(.vertical, HaloSpacing.xs)
        .frame(minHeight: 56, alignment: .top)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            Self.accessibilitySummary(
                name: name,
                preview: preview,
                timestamp: timestamp,
                isMuted: isMuted,
                isFavourite: isFavourite,
                indicator: indicator
            )
        )
    }

    private var titleRow: some View {
        HStack(spacing: HaloSpacing.xs) {
            if isFavourite {
                Image(systemName: "star.fill")
                    .foregroundStyle(HaloColor.warning)
                    .imageScale(.small)
                    .accessibilityLabel("Favourite")
            }
            Text(name)
                .font(hasUnread ? HaloTypography.body.weight(.bold) : HaloTypography.bodyEmphasis)
                .foregroundStyle(HaloColor.textPrimary)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
            if isMuted {
                Image(systemName: "bell.slash")
                    .foregroundStyle(HaloColor.textSecondary)
                    .imageScale(.small)
                    .accessibilityLabel("Muted")
            }
        }
    }

    @ViewBuilder
    private var timestampText: some View {
        if let timestamp {
            Text(timestamp)
                .font(HaloTypography.caption)
                .foregroundStyle(HaloColor.textSecondary)
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private func previewText(_ text: String) -> some View {
        let base = Text(Self.previewAttributedString(text))
            .font(HaloTypography.meta)
            .foregroundStyle(HaloColor.textSecondary)
            .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 2)
        if let previewIdentifier {
            base.accessibilityIdentifier(previewIdentifier)
        } else {
            base
        }
    }

    private static func previewAttributedString(_ text: String) -> AttributedString {
        guard let (prefix, rest) = splitPreviewPrefix(text) else {
            return AttributedString(text)
        }
        var attributed = AttributedString(prefix)
        attributed.font = HaloTypography.meta.weight(.semibold)
        attributed.append(AttributedString(rest))
        return attributed
    }
}

#Preview("RoomRow — Light") {
    List {
        RoomRow(
            name: "shirdn",
            preview: "shirdn: port: 7890\nsocks-port: 7891...",
            timestamp: "Jun 26",
            hasUnread: true,
            indicator: .count(3)
        ) {
            AvatarCircle(name: "shirdn", imageData: nil, size: 52)
        }
        RoomRow(
            name: "Moments",
            preview: "You: Image",
            timestamp: "Apr 10",
            hasUnread: false,
            isFavourite: true,
            indicator: .none
        ) {
            AvatarCircle(name: "Moments", imageData: nil, size: 52)
        }
        RoomRow(
            name: "Design Ops",
            preview: "Bob mentioned you: check the tokens",
            timestamp: "Nov 4, 2025",
            hasUnread: true,
            isMuted: true,
            indicator: .mentions(1)
        ) {
            AvatarCircle(name: "Design Ops", imageData: nil, size: 52)
        }
    }
    .listStyle(.plain)
}

#Preview("RoomRow — Dark") {
    List {
        RoomRow(
            name: "Alice",
            preview: "See you at 10:30!",
            timestamp: "10:42",
            hasUnread: true,
            indicator: .approximate
        ) {
            AvatarCircle(name: "Alice", imageData: nil, size: 52)
        }
    }
    .listStyle(.plain)
    .preferredColorScheme(.dark)
}

#Preview("RoomRow — AX5") {
    List {
        RoomRow(
            name: "Alice",
            preview: "See you at 10:30!",
            timestamp: "10:42",
            hasUnread: true,
            isFavourite: true,
            indicator: .count(3)
        ) {
            AvatarCircle(name: "Alice", imageData: nil, size: 52)
        }
    }
    .listStyle(.plain)
    .environment(\.dynamicTypeSize, .accessibility5)
}
