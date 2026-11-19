/// Whether this device's identity is trusted by the account's cross-signing keys (docs/features/ENCRYPTION_AND_DEVICES.md §6).
public enum VerificationState: Sendable, Equatable {
    case unknown
    case verified
    case unverified
}

/// Whether secret storage (the recovery key) is set up on the account and usable here.
public enum RecoveryState: Sendable, Equatable {
    case unknown
    /// Set up, and this device has the secrets.
    case enabled
    /// Not set up on the account.
    case disabled
    /// Set up, but this device doesn't have the secrets yet: the user can enter the recovery key.
    case incomplete
}

public struct EncryptionStatus: Sendable, Equatable {
    public let verification: VerificationState
    public let recovery: RecoveryState

    public init(verification: VerificationState, recovery: RecoveryState) {
        self.verification = verification
        self.recovery = recovery
    }

    public static let unknown = EncryptionStatus(verification: .unknown, recovery: .unknown)

    /// The user should be offered recovery-key entry (banner until verified, ENCRYPTION FR-4).
    public var needsRecovery: Bool { verification == .unverified && recovery == .incomplete }
}
