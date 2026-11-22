#if canImport(SwiftUI)
import HaloDesignSystem
import SwiftUI

/// S14 Notifications priming screen (`docs/design/SCREEN_SPECIFICATIONS.md` S14, AC-UX-7, UX-07).
///
/// Explains why Halo needs notifications before triggering the one-time iOS system permission prompt.
public struct NotificationPrimingView: View {
    private let onTurnOn: () async -> Void
    private let onNotNow: () -> Void
    @State private var isRequesting = false

    public init(onTurnOn: @escaping () async -> Void, onNotNow: @escaping () -> Void) {
        self.onTurnOn = onTurnOn
        self.onNotNow = onNotNow
    }

    public var body: some View {
        ScrollView {
            VStack(spacing: HaloSpacing.xl) {
                Spacer(minLength: HaloSpacing.xl)
                Image(systemName: "bell.badge.fill")
                    .font(.largeTitle)
                    .imageScale(.large)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(HaloColor.accent)
                    .accessibilityHidden(true)

                VStack(spacing: HaloSpacing.s) {
                    Text("Know when it matters")
                        .font(HaloTypography.title)
                        .foregroundStyle(HaloColor.textPrimary)
                        .multilineTextAlignment(.center)
                    Text("Halo only alerts you for the rooms and mentions you care about.")
                        .font(HaloTypography.body)
                        .foregroundStyle(HaloColor.textSecondary)
                        .multilineTextAlignment(.center)
                }

                VStack(alignment: .leading, spacing: HaloSpacing.m) {
                    benefitRow(
                        icon: "bubble.left.and.exclamationmark.bubble.right",
                        title: "Messages and mentions",
                        detail: "Get notified right away when someone writes to you or mentions you."
                    )
                    benefitRow(
                        icon: "app.badge.checkmark",
                        title: "An honest unread badge",
                        detail: "Your app icon badge stays accurate and clears the moment you read on any device."
                    )
                }
                .padding(HaloSpacing.l)
                .background(HaloColor.bgSecondary, in: RoundedRectangle(cornerRadius: HaloRadius.medium, style: .continuous))

                VStack(spacing: HaloSpacing.m) {
                    Button {
                        guard !isRequesting else { return }
                        isRequesting = true
                        Task {
                            await onTurnOn()
                            isRequesting = false
                        }
                    } label: {
                        Text(isRequesting ? "Requesting…" : "Turn on notifications")
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isRequesting)
                    .accessibilityIdentifier("turn-on-notifications")

                    Button {
                        onNotNow()
                    } label: {
                        Text("Not now")
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.bordered)
                    .disabled(isRequesting)
                    .accessibilityIdentifier("skip-notifications")
                }
            }
            .padding(.horizontal, HaloSpacing.xl)
            .padding(.bottom, HaloSpacing.xl)
        }
    }

    private func benefitRow(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: HaloSpacing.m) {
            Image(systemName: icon)
                .font(.title3)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(HaloColor.accent)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: HaloSpacing.xxs) {
                Text(title)
                    .font(HaloTypography.bodyEmphasis)
                    .foregroundStyle(HaloColor.textPrimary)
                Text(detail)
                    .font(HaloTypography.meta)
                    .foregroundStyle(HaloColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
#endif
