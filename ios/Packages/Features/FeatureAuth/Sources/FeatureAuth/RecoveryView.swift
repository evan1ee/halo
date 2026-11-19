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
                .accessibilityIdentifier("recovery-banner")
            }
        }
        .sheet(isPresented: $isPresented) { RecoveryView(model: model) }
        .onChange(of: model.isVerified) { _, verified in if verified { isPresented = false } }
    }
}

public struct RecoveryView: View {
    @Bindable private var model: RecoveryViewModel

    public init(model: RecoveryViewModel) { self.model = model }

    public var body: some View {
        VStack(spacing: 16) {
            Text("Enter your recovery key").font(.headline)
            Text("It unlocks your encrypted message history on this device.")
                .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            SecureField("Recovery key", text: $model.key).textFieldStyle(.roundedBorder)
            if model.isWorking {
                ProgressView()
            } else {
                Button("Verify") { Task { await model.submit() } }.buttonStyle(.borderedProminent)
            }
            if let message = model.errorMessage {
                Text(message).foregroundStyle(.red).font(.footnote).multilineTextAlignment(.center)
            }
        }
        .padding()
        .presentationDetents([.medium])
    }
}
#endif
