import SwiftUI

/// Skeleton loading placeholders using `.redacted(reason: .placeholder)` (`docs/design/DESIGN_SYSTEM.md` §7–8).
///
/// Used instead of a centred spinner when a list, grid, detail page, or timeline has no cached content yet.
public struct LoadingState: View {
    public enum Style: Sendable, Equatable {
        case roomList(count: Int = 8)
        case timeline(count: Int = 6)
        case rows(count: Int = 5)
        case grid(columns: Int = 3, count: Int = 9)
        case detail(rows: Int = 4)
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
                    placeholderRow(index: index)
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
        case .rows(let count):
            VStack(alignment: .leading, spacing: HaloSpacing.m) {
                ForEach(0..<max(1, count), id: \.self) { index in
                    placeholderRow(index: index)
                }
            }
            .padding(.vertical, HaloSpacing.s)
            .frame(maxWidth: .infinity, alignment: .leading)
            .redacted(reason: .placeholder)
            .allowsHitTesting(false)
            .accessibilityLabel("Loading")
        case .grid(let columns, let count):
            let columnCount = max(1, columns)
            let gridItems = Array(repeating: GridItem(.flexible(), spacing: HaloSpacing.xs), count: columnCount)
            LazyVGrid(columns: gridItems, spacing: HaloSpacing.xs) {
                ForEach(0..<max(1, count), id: \.self) { _ in
                    RoundedRectangle(cornerRadius: HaloRadius.small, style: .continuous)
                        .fill(HaloColor.bgSecondary)
                        .aspectRatio(1, contentMode: .fit)
                }
            }
            .padding(HaloSpacing.m)
            .frame(maxWidth: .infinity, alignment: .top)
            .redacted(reason: .placeholder)
            .allowsHitTesting(false)
            .accessibilityLabel("Loading media")
        case .detail(let rows):
            VStack(spacing: HaloSpacing.l) {
                VStack(spacing: HaloSpacing.s) {
                    Circle()
                        .fill(HaloColor.bgSecondary)
                        .frame(width: 80, height: 80)
                    Text("Display name placeholder")
                        .font(HaloTypography.title)
                    Text("Secondary detail placeholder")
                        .font(HaloTypography.meta)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, HaloSpacing.l)

                VStack(alignment: .leading, spacing: HaloSpacing.m) {
                    ForEach(0..<max(1, rows), id: \.self) { index in
                        VStack(alignment: .leading, spacing: HaloSpacing.xxs) {
                            Text(index.isMultiple(of: 2) ? "Detail row title" : "Additional setting")
                                .font(HaloTypography.bodyEmphasis)
                            Text("Placeholder description value")
                                .font(HaloTypography.meta)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(HaloSpacing.m)
                        .background(
                            HaloColor.bgSecondary,
                            in: RoundedRectangle(cornerRadius: HaloRadius.medium, style: .continuous)
                        )
                    }
                }
                Spacer()
            }
            .padding(.horizontal, HaloSpacing.l)
            .redacted(reason: .placeholder)
            .allowsHitTesting(false)
            .accessibilityLabel("Loading details")
        }
    }

    private func placeholderRow(index: Int) -> some View {
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

#Preview("LoadingState — Room List Light") {
    LoadingState(.roomList(count: 6))
}

#Preview("LoadingState — Timeline Dark") {
    LoadingState(.timeline(count: 5))
        .preferredColorScheme(.dark)
}

#Preview("LoadingState — Grid") {
    LoadingState(.grid(columns: 3, count: 9))
}

#Preview("LoadingState — Detail") {
    LoadingState(.detail(rows: 4))
}

#Preview("LoadingState — AX5") {
    LoadingState(.rows(count: 4))
        .padding(.horizontal)
        .environment(\.dynamicTypeSize, .accessibility5)
}
