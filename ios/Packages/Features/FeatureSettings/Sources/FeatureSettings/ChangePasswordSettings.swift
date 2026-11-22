import HaloDesignSystem
import Observation
import SwiftUI

/// What Settings → Account → Change password needs from the app (ADR-0019).
public struct ChangePasswordActions: Sendable {
    public enum Outcome: Sendable, Equatable {
        case changed
        /// The current password was wrong.
        case wrongCurrent
        /// The homeserver refused the new password (too weak or reused).
        case refusedNew
        /// Offline, throttled or a server problem; trying again may work.
        case failed
    }

    /// Whether this account's password can be changed here (not for accounts that sign in through an identity service).
    public let isAvailable: @Sendable () async -> Bool
    public let submit: @Sendable (_ current: String, _ new: String) async -> Outcome

    public init(isAvailable: @escaping @Sendable () async -> Bool, submit: @escaping @Sendable (String, String) async -> Outcome) {
        self.isAvailable = isAvailable
        self.submit = submit
    }
}

@MainActor @Observable
public final class ChangePasswordModel {
    public static let minimumLength = 8

    public var current = ""
    public var new = ""
    public var confirmation = ""
    public private(set) var isWorking = false
    public private(set) var error: String?
    public private(set) var isDone = false
    private let actions: ChangePasswordActions

    public init(actions: ChangePasswordActions) { self.actions = actions }

    /// Why the form can't be sent yet; `nil` when it can. Shown only once the user typed a new password.
    public var hint: String? {
        if new.isEmpty { return nil }
        if new.count < Self.minimumLength { return "Use at least \(Self.minimumLength) characters." }
        if new == current { return "The new password must differ from the current one." }
        if !confirmation.isEmpty, confirmation != new { return "The two new passwords don't match." }
        return nil
    }

    public var canSubmit: Bool {
        !isWorking && !current.isEmpty && new.count >= Self.minimumLength && new != current && confirmation == new
    }

    public func submit() async {
        guard canSubmit else { return }
        isWorking = true
        error = nil
        let outcome = await actions.submit(current, new)
        isWorking = false
        switch outcome {
        case .changed:
            current = ""
            new = ""
            confirmation = ""
            isDone = true
        case .wrongCurrent: error = "The current password is wrong."
        case .refusedNew: error = "The server didn't accept that password. Choose a longer or less common one."
        case .failed: error = "The password couldn't be changed. Check your connection and try again."
        }
    }
}

struct ChangePasswordView: View {
    @State private var model: ChangePasswordModel
    @Environment(\.dismiss) private var dismiss

    init(actions: ChangePasswordActions) { _model = State(initialValue: ChangePasswordModel(actions: actions)) }

    var body: some View {
        Form {
            Section {
                SecureField("Current password", text: $model.current).textContentType(.password)
            }
            Section {
                SecureField("New password", text: $model.new).textContentType(.newPassword)
                SecureField("New password again", text: $model.confirmation).textContentType(.newPassword)
            } footer: {
                if let hint = model.hint { Text(hint) } else { Text("Your other sessions stay signed in.") }
            }
            if let error = model.error {
                Section { Text(error).foregroundStyle(HaloColor.danger) }
            }
            Section {
                Button { Task { await model.submit() } } label: {
                    if model.isWorking { ProgressView().frame(maxWidth: .infinity) } else { Text("Change password").frame(maxWidth: .infinity) }
                }
                .disabled(!model.canSubmit)
                .accessibilityIdentifier("change-password-submit")
            }
        }
        .navigationTitle("Change password")
        .alert("Password changed", isPresented: Binding(get: { model.isDone }, set: { _ in })) {
            Button("OK") { dismiss() }
        }
    }
}
