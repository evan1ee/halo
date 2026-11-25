import HaloDesignSystem
import SwiftUI

/// What Settings → Security needs to reset the end-to-end identity (ENCRYPTION_AND_DEVICES FR-8, AC-SEC-3).
public struct IdentityResetActions: Sendable {
    public enum Need: Sendable, Equatable {
        case nothing
        case password
        /// The account's web page, where the person approves the reset.
        case browser(URL)
    }

    public let prepare: @MainActor @Sendable () async -> Result<Need, SettingsMessage>
    /// Resets and returns the new recovery key.
    public let reset: @MainActor @Sendable (_ password: String?) async -> Result<String, SettingsMessage>
    public let cancel: @MainActor @Sendable () async -> Void

    public init(
        prepare: @escaping @MainActor @Sendable () async -> Result<Need, SettingsMessage>,
        reset: @escaping @MainActor @Sendable (_ password: String?) async -> Result<String, SettingsMessage>,
        cancel: @escaping @MainActor @Sendable () async -> Void
    ) {
        self.prepare = prepare
        self.reset = reset
        self.cancel = cancel
    }
}

/// "Lost your recovery key?": says plainly what is lost and what stays, then resets (FR-8, AC-SEC-3).
struct IdentityResetSheet: View {
    let actions: IdentityResetActions
    /// Called with the new recovery key once the reset is done.
    let finished: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var need: IdentityResetActions.Need?
    @State private var password = ""
    @State private var isWorking = false
    @State private var message: String?
    @State private var approvalOpened = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Use this only if you have lost your recovery key and have no other device that is signed in to this account.")
                }
                Section("What you lose") {
                    Label("Messages that only your old key backup held can't be restored on any device. Messages already on a device that can read them stay.", systemImage: "clock.arrow.circlepath")
                    Label("Your contacts will see that your security identity changed, and may need to accept it. Anyone who had verified you will have to verify you again.", systemImage: "person.2")
                    Label("Your other signed-in devices become unverified.", systemImage: "iphone.slash")
                }
                Section("What stays") {
                    Label("Your account, chats and contacts.", systemImage: "checkmark.circle")
                    Label("This device becomes verified and gets a new recovery key, which you save right after.", systemImage: "key")
                }
                if let need { requirement(need) } else {
                    Section {
                        Button("Continue") { Task { await prepare() } }
                            .disabled(isWorking)
                            .accessibilityIdentifier("identity-reset-continue")
                    }
                }
                if let message {
                    Section { Text(message).foregroundStyle(HaloColor.danger).accessibilityIdentifier("identity-reset-message") }
                }
            }
            .navigationTitle("Reset identity")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { Task { await actions.cancel(); dismiss() } } } }
            .disabled(isWorking)
        }
    }

    @ViewBuilder private func requirement(_ need: IdentityResetActions.Need) -> some View {
        switch need {
        case .nothing:
            Section { Text("This account has no end-to-end identity yet, so there is nothing to reset.") }
        case .password:
            Section("Your account password") {
                SecureField("Password", text: $password)
                    .textContentType(.password)
                    .accessibilityIdentifier("identity-reset-password")
                resetButton
            }
        case .browser(let url):
            Section("Approve on your account page") {
                Button("Open the approval page") { approvalOpened = true; openURL(url) }
                    .accessibilityIdentifier("identity-reset-open")
                if approvalOpened { resetButton }
            }
        }
    }

    private var resetButton: some View {
        Button(isWorking ? "Resetting…" : "Reset identity and create a new key", role: .destructive) { Task { await reset() } }
            .disabled(isWorking)
            .accessibilityIdentifier("identity-reset-confirm")
    }

    private func prepare() async {
        isWorking = true
        defer { isWorking = false }
        switch await actions.prepare() {
        case .success(let need): self.need = need; message = nil
        case .failure(let failure): message = failure.text
        }
    }

    private func reset() async {
        isWorking = true
        defer { isWorking = false }
        switch await actions.reset(need == .password ? password : nil) {
        case .success(let key): password = ""; finished(key)
        case .failure(let failure): message = failure.text
        }
    }
}
