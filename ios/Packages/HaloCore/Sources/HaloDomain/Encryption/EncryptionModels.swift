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

/// Whether this account's message keys are backed up on the server, so a new device can read old messages.
public enum BackupState: Sendable, Equatable {
    case unknown
    /// No backup is running.
    case off
    /// Being created, resumed or switched off.
    case working
    /// Keys are backed up.
    case on
}

/// What the person must give to reset their end-to-end identity (M18-3).
public enum IdentityResetRequirement: Sendable, Equatable {
    /// The account has no identity to reset.
    case nothingToReset
    /// The account's password.
    case password
    /// Approval on the account's web page; `approvalURL` is where to send the person.
    case approveInBrowser(approvalURL: String)
}

public struct EncryptionStatus: Sendable, Equatable {
    public let verification: VerificationState
    public let recovery: RecoveryState
    public let backup: BackupState

    public init(verification: VerificationState, recovery: RecoveryState, backup: BackupState = .unknown) {
        self.verification = verification
        self.recovery = recovery
        self.backup = backup
    }

    public static let unknown = EncryptionStatus(verification: .unknown, recovery: .unknown)

    /// The user should be offered recovery-key entry or SAS verification (banner until verified, ENCRYPTION FR-2, FR-4).
    public var needsRecovery: Bool { verification == .unverified && recovery == .incomplete }
}

/// One emoji shown during SAS (short authentication string) device verification (ENCRYPTION_AND_DEVICES FR-2).
public struct VerificationEmoji: Sendable, Equatable, Hashable {
    public let symbol: String
    public let description: String

    public init(symbol: String, description: String) {
        self.symbol = symbol
        self.description = description
    }
}

/// Details of an incoming SAS verification request from another session (ENCRYPTION_AND_DEVICES FR-2).
public struct VerificationRequest: Sendable, Equatable {
    public let senderID: String
    public let flowID: String
    public let deviceID: String
    public let deviceDisplayName: String?

    public init(senderID: String, flowID: String, deviceID: String, deviceDisplayName: String?) {
        self.senderID = senderID
        self.flowID = flowID
        self.deviceID = deviceID
        self.deviceDisplayName = deviceDisplayName
    }
}

/// Interactive SAS (emoji / decimal) device verification state machine (ENCRYPTION_AND_DEVICES FR-2, §6).
public enum SessionVerificationPhase: Sendable, Equatable {
    case idle
    /// Another session requested verification with this device.
    case incomingRequest(VerificationRequest)
    /// This device requested verification and is waiting for another signed-in session to accept.
    case waitingForOtherDevice
    /// The verification request was accepted; negotiating SAS (emoji / decimal) comparison data.
    case startingSAS
    /// SAS emojis are ready for the user to compare across both screens.
    case comparingEmojis([VerificationEmoji])
    /// SAS decimal numbers are ready for the user to compare across both screens.
    case comparingDecimals([UInt16])
    /// This device approved the match and is waiting for the other session to confirm.
    case waitingForPartnerConfirmation
    /// Both sessions confirmed the match; cross-signing keys and backup secrets are exchanged.
    case verified
    /// Verification was cancelled by either side, with an optional human-readable reason.
    case cancelled(reason: String?)
    /// Verification failed.
    case failed(String)
}
