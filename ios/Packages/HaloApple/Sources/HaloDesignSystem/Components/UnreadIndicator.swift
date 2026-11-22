import SwiftUI

/// Unread attention indicator (`docs/design/DESIGN_SYSTEM.md` §7).
///
/// Renders dot, count (1–99, "99+"), mention (`@n`), or approximate (dot with a ring) using semantic tokens.
public struct UnreadIndicator: View {
    public enum Style: Sendable, Equatable {
        case none
        case dot
        case count(Int)
        case mentions(Int)
        case approximate
    }

    private let style: Style

    public init(_ style: Style) {
        self.style = style
    }

    public var body: some View {
        switch style {
        case .none:
            EmptyView()
        case .dot:
            Circle()
                .fill(HaloColor.attention)
                .frame(width: 9, height: 9)
                .accessibilityLabel("Unread")
        case .approximate:
            ZStack {
                Circle()
                    .strokeBorder(HaloColor.attention.opacity(0.45), lineWidth: 1.5)
                    .frame(width: 15, height: 15)
                Circle()
                    .fill(HaloColor.attention)
                    .frame(width: 8, height: 8)
            }
            .accessibilityLabel("Unread (approximate)")
        case .count(let n):
            Text(Self.formatCount(n))
                .font(HaloTypography.captionEmphasis)
                .padding(.horizontal, 7)
                .padding(.vertical, HaloSpacing.xxs)
                .background(HaloColor.attention, in: Capsule())
                .foregroundStyle(HaloColor.onAttention)
                .accessibilityLabel(n == 1 ? "1 unread message" : "\(n) unread messages")
        case .mentions(let n):
            Text("@\(Self.formatCount(n))")
                .font(HaloTypography.captionEmphasis)
                .padding(.horizontal, 7)
                .padding(.vertical, HaloSpacing.xxs)
                .background(HaloColor.mention, in: Capsule())
                .foregroundStyle(HaloColor.onMention)
                .accessibilityLabel(n == 1 ? "1 mention" : "\(n) mentions")
        }
    }

    public static func formatCount(_ count: Int) -> String {
        count > 99 ? "99+" : "\(max(0, count))"
    }
}

#Preview("UnreadIndicator — Light") {
    HStack(spacing: HaloSpacing.l) {
        UnreadIndicator(.dot)
        UnreadIndicator(.approximate)
        UnreadIndicator(.count(3))
        UnreadIndicator(.count(142))
        UnreadIndicator(.mentions(2))
    }
    .padding()
}

#Preview("UnreadIndicator — Dark") {
    HStack(spacing: HaloSpacing.l) {
        UnreadIndicator(.dot)
        UnreadIndicator(.approximate)
        UnreadIndicator(.count(3))
        UnreadIndicator(.mentions(2))
    }
    .padding()
    .preferredColorScheme(.dark)
}

#Preview("UnreadIndicator — AX5") {
    HStack(spacing: HaloSpacing.l) {
        UnreadIndicator(.dot)
        UnreadIndicator(.count(12))
        UnreadIndicator(.mentions(1))
    }
    .padding()
    .environment(\.dynamicTypeSize, .accessibility5)
}
