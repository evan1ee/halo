#if canImport(SwiftUI)
import SwiftUI

/// A banner shown above the room list while the device is unverified; tapping it presents `RecoveryView`.
/// The composition root must call `RecoveryViewModel.start()`: a hidden banner is an empty view and runs no `.task`.
public struct RecoveryBanner: View {
    private let model: RecoveryViewModel
    @State private var isPresented = false

    public init(model: RecoveryViewModel) { self.model = model }

    public var body: some View {
        Group {
            if model.needsRecovery {
                Button {
                    isPresented = true
                } label: {
                    Label("Verify this device to read older encrypted messages", systemImage: "lock.shield")
                        .font(.footnote)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(.yellow.opacity(0.25))
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
    }
}

public struct RecoveryView: View {
    @Bindable private var model: RecoveryViewModel
    @Environment(\.dismiss) private var dismiss
    @FocusState private var keyFocused: Bool

    public init(model: RecoveryViewModel) { self.model = model }

    private var canSubmit: Bool { !model.key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    public var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "lock.shield").font(.system(size: 40)).foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text("Enter your recovery key").font(.title3.bold())
            Text("It unlocks your encrypted message history on this device.")
                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
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
                Button { Task { await model.submit() } } label: { Text("Verify").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(!canSubmit)
                Button("Not now") { dismiss() }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .padding(.top, 28)
        .onAppear { keyFocused = true }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }
}
#endif
