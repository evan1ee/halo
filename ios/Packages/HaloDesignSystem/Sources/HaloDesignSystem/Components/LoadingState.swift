import SwiftUI

/// Skeleton loading placeholders using `.redacted(reason: .placeholder)` (`docs/design/DESIGN_SYSTEM.md` §7–8).
///
/// Used instead of a centred spinner when a list or timeline has no cached content yet.
public struct LoadingState: View {
    public enum Style: Sendable, Equatable {
        case roomList(count: Int = 8)
        case timeline(count: Int = 6)
    }

    private let style: Style

    public init(_ style: Style = .roomList()) {
        self.style = style
    }

    public var body: some View {
        switch style {
        case .roomList(let count):
            List {
                ForEach(0..<max(1, count), id: \.self) { index in
                    HStack(spacing: HaloSpacing.m) {
                        Circle()
                            .fill(HaloColor.bgSecondary)
                            .frame(width: 40, height: 40)
                        VStack(alignment: .leading, spacing: HaloSpacing.xs) {
                            HStack {
                                Text(index.isMultiple(of: 2) ? "Conversation name" : "Project channel")
                                    .font(HaloTypography.bodyEmphasis)
                                Spacer()
                                Text("10:42")
                                    .font(HaloTypography.caption)
                            }
                            Text("Latest message preview placeholder text")
                                .font(HaloTypography.meta)
                                .lineLimit(1)
                        }
                    }
                    .padding(.vertical, HaloSpacing.xxs)
                }
            }
            .redacted(reason: .placeholder)
            .allowsHitTesting(false)
            .accessibilityLabel("Loading conversations")
        case .timeline(let count):
            VStack(alignment: .leading, spacing: HaloSpacing.m) {
                ForEach(0..<max(1, count), id: \.self) { index in
                    let isOwn = index.isMultiple(of: 2)
                    HStack {
                        if isOwn { Spacer(minLength: 60) }
                        Text(isOwn ? "Placeholder sent message" : "Placeholder received message text here")
                            .font(HaloTypography.body)
                            .padding(.horizontal, HaloSpacing.m)
                            .padding(.vertical, HaloSpacing.s)
                            .background(
                                isOwn ? HaloColor.bubbleOwn : HaloColor.bubbleOther,
                                in: RoundedRectangle(cornerRadius: HaloRadius.bubble, style: .continuous)
                            )
                        if !isOwn { Spacer(minLength: 60) }
                    }
                }
                Spacer()
            }
            .padding(HaloSpacing.l)
            .redacted(reason: .placeholder)
            .allowsHitTesting(false)
            .accessibilityLabel("Loading messages")
        }
    }
}

#Preview("LoadingState — Room List Light") {
    LoadingState(.roomList(count: 6))
}

#Preview("LoadingState — Timeline Dark") {
    LoadingState(.timeline(count: 5))
        .preferredColorScheme(.dark)
}

#Preview("LoadingState — AX5") {
    LoadingState(.roomList(count: 4))
        .environment(\.dynamicTypeSize, .accessibility5)
}
