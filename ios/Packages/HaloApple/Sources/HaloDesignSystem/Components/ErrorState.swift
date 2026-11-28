import SwiftUI

/// Error presentation in full-screen or inline layout (`docs/design/DESIGN_SYSTEM.md` §7–8).
public struct ErrorState: View {
    public enum Layout: Sendable, Equatable {
        case fullScreen
        case inline
    }

    @Environment(\.dynamicTypeSize) private var typeSize

    private let layout: Layout
    private let icon: String
    private let title: String
    private let message: String
    private let retryTitle: String
    private let onRetry: (() -> Void)?

    public init(
        layout: Layout = .fullScreen,
        icon: String = "exclamationmark.triangle",
        title: String,
        message: String,
        retryTitle: String = "Try again",
        onRetry: (() -> Void)? = nil
    ) {
        self.layout = layout
        self.icon = icon
        self.title = title
        self.message = message
        self.retryTitle = retryTitle
        self.onRetry = onRetry
    }

    public var body: some View {
        switch layout {
        case .fullScreen:
            ContentUnavailableView {
                Label(title, systemImage: icon)
            } description: {
                Text(message)
            } actions: {
                if let onRetry {
                    Button(retryTitle, action: onRetry)
                        .buttonStyle(.borderedProminent)
                }
            }
        case .inline:
            inlineBody
                .padding(HaloSpacing.m)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    HaloColor.bgSecondary,
                    in: RoundedRectangle(cornerRadius: HaloRadius.medium, style: .continuous)
                )
        }
    }

    @ViewBuilder
    private var inlineBody: some View {
        if typeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: HaloSpacing.s) {
                inlineLabel
                if let onRetry {
                    Button(retryTitle, action: onRetry)
                        .font(HaloTypography.meta.weight(.semibold))
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
        } else {
            HStack(alignment: .top, spacing: HaloSpacing.s) {
                inlineLabel
                Spacer(minLength: HaloSpacing.xs)
                if let onRetry {
                    Button(retryTitle, action: onRetry)
                        .font(HaloTypography.meta.weight(.semibold))
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
        }
    }

    private var inlineLabel: some View {
        HStack(alignment: .top, spacing: HaloSpacing.s) {
            Image(systemName: icon == "exclamationmark.triangle" ? "exclamationmark.triangle.fill" : icon)
                .foregroundStyle(HaloColor.danger)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: HaloSpacing.xxs) {
                Text(title)
                    .font(HaloTypography.bodyEmphasis)
                    .foregroundStyle(HaloColor.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(message)
                    .font(HaloTypography.meta)
                    .foregroundStyle(HaloColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

#Preview("ErrorState — Full Screen Light") {
    ErrorState(title: "Couldn't load rooms", message: "Check your connection and try again.", onRetry: {})
}

#Preview("ErrorState — Inline Dark") {
    ErrorState(layout: .inline, title: "Couldn't load media", message: "Tap to try again.", onRetry: {})
        .padding()
        .preferredColorScheme(.dark)
}

#Preview("ErrorState — AX5") {
    ErrorState(layout: .inline, title: "Couldn't load media", message: "Tap to try again.", onRetry: {})
        .padding()
        .environment(\.dynamicTypeSize, .accessibility5)
}
