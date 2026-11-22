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

    public var body: some View {
        HStack(spacing: HaloSpacing.m) {
            avatar
            VStack(alignment: .leading, spacing: HaloSpacing.xxs) {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: HaloSpacing.xxs) {
                        titleRow
                        metaRow
                    }
                } else {
                    HStack(spacing: HaloSpacing.xs) {
                        titleRow
                        Spacer(minLength: HaloSpacing.xs)
                        metaRow
                    }
                }
                if let preview {
                    previewText(preview)
                }
            }
        }
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
                .font(hasUnread ? HaloTypography.bodyEmphasis : HaloTypography.body)
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

    private var metaRow: some View {
        HStack(spacing: HaloSpacing.xs) {
            if let timestamp {
                Text(timestamp)
                    .font(HaloTypography.caption)
                    .foregroundStyle(HaloColor.textSecondary)
            }
            UnreadIndicator(indicator)
        }
    }

    @ViewBuilder
    private func previewText(_ text: String) -> some View {
        let base = Text(text)
            .font(HaloTypography.meta)
            .foregroundStyle(HaloColor.textSecondary)
            .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 1)
        if let previewIdentifier {
            base.accessibilityIdentifier(previewIdentifier)
        } else {
            base
        }
    }
}

#Preview("RoomRow — Light") {
    List {
        RoomRow(
            name: "Alice",
            preview: "See you at 10:30!",
            timestamp: "10:42",
            hasUnread: true,
            isFavourite: true,
            indicator: .count(3)
        ) {
            AvatarCircle(name: "Alice", imageData: nil, size: 40)
        }
        RoomRow(
            name: "Design Ops",
            preview: "Bob mentioned you: check the tokens",
            timestamp: "Yesterday",
            hasUnread: true,
            isMuted: true,
            indicator: .mentions(1)
        ) {
            AvatarCircle(name: "Design Ops", imageData: nil, size: 40)
        }
    }
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
            AvatarCircle(name: "Alice", imageData: nil, size: 40)
        }
    }
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
            AvatarCircle(name: "Alice", imageData: nil, size: 40)
        }
    }
    .environment(\.dynamicTypeSize, .accessibility5)
}
