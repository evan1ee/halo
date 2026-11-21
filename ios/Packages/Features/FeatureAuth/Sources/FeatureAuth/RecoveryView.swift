#if canImport(SwiftUI)
import HaloDomain
import SwiftUI

/// A banner shown above the room list while the device is unverified or has an incoming verification request;
/// tapping it presents `RecoveryView`.
/// The composition root must call `RecoveryViewModel.start()`: a hidden banner is an empty view and runs no `.task`.
public struct RecoveryBanner: View {
    private let model: RecoveryViewModel
    @State private var isPresented = false

    public init(model: RecoveryViewModel) { self.model = model }

    private var hasIncomingRequest: Bool {
        if case .incomingRequest = model.verificationPhase { return true }
        return false
    }

    public var body: some View {
        Group {
            if model.needsRecovery || hasIncomingRequest {
                Button {
                    isPresented = true
                } label: {
                    HStack(spacing: 8) {
                        Label(
                            hasIncomingRequest
                                ? "Verification request from another device"
                                : "Verify this device to read older encrypted messages",
                            systemImage: "lock.shield")
                        Spacer(minLength: 4)
                        Image(systemName: "chevron.right").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    }
                    .font(.footnote)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(.yellow.opacity(0.22), ignoresSafeAreaEdges: [])
                }
                .buttonStyle(.plain)
                .transition(.move(edge: .top).combined(with: .opacity))
                .accessibilityIdentifier("recovery-banner")
            }
        }
        // It appears once the account's state is known, a moment after launch: slide it in rather than jump the list.
        .animation(.easeOut(duration: 0.25), value: model.needsRecovery)
        .sheet(isPresented: $isPresented) { RecoveryView(model: model) }
        .onChange(of: model.isVerified) { _, verified in if verified { isPresented = false } }
        .onChange(of: hasIncomingRequest) { _, incoming in if incoming { isPresented = true } }
    }
}

public struct RecoveryView: View {
    @Bindable private var model: RecoveryViewModel
    @Environment(\.dismiss) private var dismiss
    @FocusState private var keyFocused: Bool

    public init(model: RecoveryViewModel) { self.model = model }

    private var canSubmit: Bool { !model.key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    public var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Image(systemName: "lock.shield").font(.system(size: 40)).foregroundStyle(.tint)
                    .accessibilityHidden(true)

                switch model.verificationPhase {
                case .idle:
                    idleContent
                case .incomingRequest(let request):
                    incomingRequestContent(request)
                case .waitingForOtherDevice:
                    waitingContent(
                        title: "Waiting for your other device…",
                        subtitle: "Accept the verification prompt on your other signed-in session.")
                case .startingSAS:
                    waitingContent(
                        title: "Starting emoji comparison…",
                        subtitle: "Generating matching security emojis with your other device.")
                case .comparingEmojis(let emojis):
                    comparingEmojisContent(emojis)
                case .comparingDecimals(let decimals):
                    comparingDecimalsContent(decimals)
                case .waitingForPartnerConfirmation:
                    waitingContent(
                        title: "Waiting for the other device…",
                        subtitle: "Confirm that the emojis match on your other device as well.")
                case .verified:
                    verifiedContent
                case .cancelled(let reason):
                    statusNoticeContent(
                        title: "Verification cancelled",
                        detail: reason ?? "The verification request was cancelled.")
                case .failed(let code):
                    statusNoticeContent(
                        title: "Verification couldn't complete",
                        detail: "Try again with your other device or use your recovery key (\(code)).")
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .padding(.bottom, 16)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    @ViewBuilder
    private var idleContent: some View {
        Text("Verify this device").font(.title3.bold())
        Text("Compare emojis with another signed-in device or enter your recovery key to unlock encrypted history.")
            .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)

        Button {
            Task { await model.requestDeviceVerification() }
        } label: {
            Label("Verify with another device", systemImage: "iphone.gen3.radiowaves.left.and.right")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .accessibilityIdentifier("verify-other-device")

        Divider().padding(.vertical, 4)

        SecureField("Recovery key", text: $model.key).textFieldStyle(.roundedBorder)
            .focused($keyFocused)
            .autocorrectionDisabled()
            #if os(iOS)
            .textInputAutocapitalization(.never)
            #endif
            .submitLabel(.go).onSubmit { if canSubmit { Task { await model.submit() } } }
        if let message = model.errorMessage {
            Text(message).foregroundStyle(.red).font(.footnote).multilineTextAlignment(.center)
        }
        if model.isWorking {
            ProgressView().frame(minHeight: 44)
        } else {
            Button { Task { await model.submit() } } label: { Text("Verify with recovery key").frame(maxWidth: .infinity) }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .disabled(!canSubmit)
                .accessibilityIdentifier("verify-recovery-key")
            Button("Not now") { dismiss() }
        }
    }

    @ViewBuilder
    private func incomingRequestContent(_ request: VerificationRequest) -> some View {
        Text("Verification request").font(.title3.bold())
        Text("\(request.deviceDisplayName ?? request.deviceID) wants to verify with this device.")
            .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
        HStack(spacing: 12) {
            Button(role: .cancel) {
                Task { await model.cancelVerification() }
            } label: {
                Text("Decline").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)

            Button {
                Task { await model.acceptVerificationRequest() }
            } label: {
                Text("Compare emojis").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .accessibilityIdentifier("accept-verification")
        }
    }

    @ViewBuilder
    private func waitingContent(title: String, subtitle: String) -> some View {
        Text(title).font(.title3.bold())
        Text(subtitle)
            .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
        ProgressView().padding(.vertical, 8)
        Button("Cancel") {
            Task { await model.cancelVerification() }
        }
        .accessibilityIdentifier("cancel-verification")
    }

    @ViewBuilder
    private func comparingEmojisContent(_ emojis: [VerificationEmoji]) -> some View {
        Text("Do these emojis match?").font(.title3.bold())
        Text("Check that the same 7 emojis appear in the same order on your other device.")
            .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)

        LazyVGrid(columns: [GridItem(.adaptive(minimum: 72), spacing: 12)], spacing: 12) {
            ForEach(Array(emojis.enumerated()), id: \.offset) { _, emoji in
                VStack(spacing: 4) {
                    Text(emoji.symbol).font(.system(size: 32))
                    Text(emoji.description).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity)
                .background(.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .accessibilityIdentifier("sas-emojis")

        HStack(spacing: 12) {
            Button(role: .destructive) {
                Task { await model.declineVerification() }
            } label: {
                Text("They don't match").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .accessibilityIdentifier("decline-sas")

            Button {
                Task { await model.approveVerification() }
            } label: {
                Text("They match").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .accessibilityIdentifier("approve-sas")
        }
    }

    @ViewBuilder
    private func comparingDecimalsContent(_ decimals: [UInt16]) -> some View {
        Text("Do these numbers match?").font(.title3.bold())
        Text("Check that the same numbers appear on your other device.")
            .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
        Text(decimals.map(String.init).joined(separator: "  "))
            .font(.title2.monospacedDigit().bold())
            .padding()
            .background(.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            .accessibilityIdentifier("sas-decimals")
        HStack(spacing: 12) {
            Button(role: .destructive) {
                Task { await model.declineVerification() }
            } label: {
                Text("They don't match").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)

            Button {
                Task { await model.approveVerification() }
            } label: {
                Text("They match").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }

    @ViewBuilder
    private var verifiedContent: some View {
        Text("Device verified").font(.title3.bold())
        Text("Your encrypted message history is now unlocked.")
            .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
        Button {
            dismiss()
        } label: {
            Text("Done").frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
    }

    @ViewBuilder
    private func statusNoticeContent(title: String, detail: String) -> some View {
        Text(title).font(.title3.bold())
        Text(detail)
            .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
        Button {
            Task { await model.cancelVerification() }
        } label: {
            Text("Back").frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
    }
}
#endif
