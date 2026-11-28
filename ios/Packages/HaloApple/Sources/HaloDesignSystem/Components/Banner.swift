import SwiftUI

/// Status banner for offline state, unverified device, soft logout, or inline errors (`docs/design/DESIGN_SYSTEM.md` §7).
public struct HaloBanner: View {
    public enum Tone: Sendable, Equatable {
        case info
        case warning
        case danger

        var tint: Color {
            switch self {
            case .info: HaloColor.accent
            case .warning: HaloColor.warning
            case .danger: HaloColor.danger
            }
        }
    }

    private let tone: Tone
    private let icon: String
    private let message: String
    private let actionTitle: String?
    private let onAction: (() -> Void)?
    private let onDismiss: (() -> Void)?

    public init(
        tone: Tone,
        icon: String,
        message: String,
        actionTitle: String? = nil,
        onAction: (() -> Void)? = nil,
        onDismiss: (() -> Void)? = nil
    ) {
        self.tone = tone
        self.icon = icon
        self.message = message
        self.actionTitle = actionTitle
        self.onAction = onAction
        self.onDismiss = onDismiss
    }

    @Environment(\.dynamicTypeSize) private var typeSize

    public var body: some View {
        Group {
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: HaloSpacing.s) {
                    HStack(alignment: .top, spacing: HaloSpacing.s) {
                        bannerLabel
                        Spacer(minLength: HaloSpacing.xs)
                        dismissButton
                    }
                    actionButton
                }
            } else {
                HStack(spacing: HaloSpacing.s) {
                    bannerLabel
                    Spacer(minLength: HaloSpacing.xs)
                    actionButton
                    dismissButton
                }
            }
        }
        .padding(.horizontal, HaloSpacing.m)
        .padding(.vertical, HaloSpacing.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
    }

    private var bannerLabel: some View {
        HStack(alignment: .top, spacing: HaloSpacing.s) {
            Image(systemName: icon)
                .foregroundStyle(tone.tint)
                .symbolRenderingMode(.hierarchical)
                .accessibilityHidden(true)
            Text(message)
                .font(HaloTypography.meta)
                .foregroundStyle(HaloColor.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        if let actionTitle, let onAction {
            Button(actionTitle, action: onAction)
                .font(HaloTypography.meta.weight(.semibold))
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
    }

    @ViewBuilder
    private var dismissButton: some View {
        if let onDismiss {
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(HaloTypography.captionEmphasis)
                    .frame(minWidth: 28, minHeight: 28)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .foregroundStyle(HaloColor.textSecondary)
            .accessibilityLabel("Dismiss")
        }
    }
}

#Preview("HaloBanner — Light") {
    VStack(spacing: HaloSpacing.s) {
        HaloBanner(tone: .warning, icon: "wifi.slash", message: "Offline — messages will send when you reconnect.")
        HaloBanner(tone: .warning, icon: "lock.shield", message: "Verify this device to read encrypted history.", actionTitle: "Verify", onAction: {})
        HaloBanner(tone: .danger, icon: "exclamationmark.triangle.fill", message: "Couldn't complete action.", onDismiss: {})
    }
}

#Preview("HaloBanner — Dark") {
    HaloBanner(tone: .danger, icon: "exclamationmark.triangle.fill", message: "Couldn't complete action.", onDismiss: {})
        .preferredColorScheme(.dark)
}

#Preview("HaloBanner — AX5") {
    HaloBanner(tone: .warning, icon: "lock.shield", message: "Verify this device to read encrypted history.", actionTitle: "Verify", onAction: {})
        .environment(\.dynamicTypeSize, .accessibility5)
}
