#if canImport(SwiftUI)
import HaloDesignSystem
import SwiftUI

/// S15 First-run setup checklist (`docs/design/SCREEN_SPECIFICATIONS.md` S15, M13).
///
/// Guides a newly signed-in user through device verification (S2) and notifications priming (S14).
/// Each step is skippable and completes automatically when satisfied elsewhere.
public struct FirstRunChecklistView: View {
    private let recovery: RecoveryViewModel
    private let notificationsEnabled: Bool
    private let onRequestNotifications: () async -> Void
    private let onFinish: () -> Void

    @State private var showingVerify = false
    @State private var showingNotifications = false
    @State private var skippedVerify = false
    @State private var skippedNotifications = false

    public init(
        recovery: RecoveryViewModel,
        notificationsEnabled: Bool,
        onRequestNotifications: @escaping () async -> Void,
        onFinish: @escaping () -> Void
    ) {
        self.recovery = recovery
        self.notificationsEnabled = notificationsEnabled
        self.onRequestNotifications = onRequestNotifications
        self.onFinish = onFinish
    }

    private var verifyDone: Bool { !recovery.needsRecovery }
    private var allDone: Bool { verifyDone && notificationsEnabled }

    public var body: some View {
        NavigationStack {
            List {
                Section {
                    stepRow(
                        title: "Verify this device",
                        detail: verifyDone ? "Encrypted history is unlocked." : "Read older encrypted messages and confirm your session.",
                        isDone: verifyDone,
                        isSkipped: skippedVerify && !verifyDone,
                        actionTitle: "Verify"
                    ) {
                        showingVerify = true
                    }
                    stepRow(
                        title: "Turn on notifications",
                        detail: notificationsEnabled ? "Alerts and badge updates are enabled." : "Know when you have messages or mentions.",
                        isDone: notificationsEnabled,
                        isSkipped: skippedNotifications && !notificationsEnabled,
                        actionTitle: "Set up"
                    ) {
                        showingNotifications = true
                    }
                } header: {
                    Text(allDone ? "You're all set" : "Finish setting up Halo")
                } footer: {
                    Text("You can always change these later in Settings.")
                }

                Section {
                    Button {
                        onFinish()
                    } label: {
                        Text(allDone ? "Start chatting" : "Continue to Chats")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("finish-onboarding")
                }
            }
            .navigationTitle("Welcome to Halo")
            .sheet(isPresented: $showingVerify) {
                RecoveryView(model: recovery)
            }
            .sheet(isPresented: $showingNotifications) {
                NotificationPrimingView(
                    onTurnOn: {
                        await onRequestNotifications()
                        showingNotifications = false
                    },
                    onNotNow: {
                        skippedNotifications = true
                        showingNotifications = false
                    }
                )
            }
        }
    }

    private func stepRow(
        title: String,
        detail: String,
        isDone: Bool,
        isSkipped: Bool,
        actionTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: HaloSpacing.m) {
            Image(systemName: isDone ? "checkmark.circle.fill" : (isSkipped ? "minus.circle" : "circle"))
                .font(.title3)
                .foregroundStyle(isDone ? HaloColor.success : HaloColor.textSecondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: HaloSpacing.xxs) {
                Text(title).font(HaloTypography.bodyEmphasis)
                Text(detail).font(HaloTypography.meta).foregroundStyle(HaloColor.textSecondary)
            }
            Spacer(minLength: HaloSpacing.s)
            if !isDone {
                Button(actionTitle, action: action)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(.vertical, HaloSpacing.xxs)
    }
}
#endif
