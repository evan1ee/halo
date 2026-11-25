import HaloFoundation

/// End-to-end encryption state, recovery and SAS (emoji / decimal) session verification
/// (docs/matrix/PORTS_CONTRACT.md §2, docs/features/ENCRYPTION_AND_DEVICES.md).
/// Implemented by `HaloMatrixAdapter`; faked in `HaloTestSupport`. Keys never cross this port: the recovery key is the
/// user's input (`recover`) or the one-time output of `enableRecovery`, and callers must not store or log it
/// (docs/security/SECURITY.md §3).
public protocol EncryptionPort: Sendable {
    /// The current status, then every change. Snapshot semantics: the latest value wins (CONCURRENCY §3).
    func statuses() -> AsyncStream<EncryptionStatus>

    /// Restores secrets and key backup with the user's recovery key, which verifies this device. A key that
    /// doesn't match throws `.invalidInput("RECOVERY_KEY")`.
    func recover(recoveryKey: String) async throws(HaloError)

    /// Creates secret storage and backup and returns the new recovery key, to be shown to the user once.
    func enableRecovery() async throws(HaloError) -> String

    /// Replaces the account's recovery key and key backup with new ones and returns the new key. Messages that are only
    /// in the old backup can no longer be restored: callers confirm with the user first.
    func resetRecovery() async throws(HaloError) -> String

    /// Starts resetting the account's end-to-end identity (for someone who lost the recovery key and every other device) and
    /// says what the person has to give. Nothing changes until `resetIdentity(password:)`.
    func prepareIdentityReset() async throws(HaloError) -> IdentityResetRequirement

    /// Resets the identity (new cross-signing keys, backup and recovery key deleted), makes this device verified, and
    /// creates a new recovery key, returned to be shown once. `password` is for `.password`; `.approveInBrowser` needs the
    /// approval done first. Messages only the old backup held can no longer be restored: callers confirm first (FR-8).
    func resetIdentity(password: String?) async throws(HaloError) -> String

    /// Drops a prepared reset without doing it.
    func cancelIdentityReset() async

    /// Interactive SAS (emoji / decimal) verification phases (`SessionVerificationController`).
    func verificationPhases() -> AsyncStream<SessionVerificationPhase>

    /// Requests verification of this device from the account's other signed-in devices (FR-2).
    func requestDeviceVerification() async throws(HaloError)

    /// Accepts an incoming verification request from another device and transitions into SAS verification (FR-2).
    func acceptVerificationRequest() async throws(HaloError)

    /// Confirms that the SAS emojis or decimals match on both devices (FR-2).
    func approveVerification() async throws(HaloError)

    /// Rejects a mismatched SAS comparison (FR-2).
    func declineVerification() async throws(HaloError)

    /// Cancels an in-progress verification request (FR-2).
    func cancelVerification() async throws(HaloError)
}

extension EncryptionPort {
    public func prepareIdentityReset() async throws(HaloError) -> IdentityResetRequirement { throw .unsupported("IDENTITY_RESET") }
    public func resetIdentity(password: String?) async throws(HaloError) -> String { throw .unsupported("IDENTITY_RESET") }
    public func cancelIdentityReset() async {}
    public func verificationPhases() -> AsyncStream<SessionVerificationPhase> {
        AsyncStream { continuation in
            continuation.yield(.idle)
            continuation.finish()
        }
    }

    public func requestDeviceVerification() async throws(HaloError) {}
    public func acceptVerificationRequest() async throws(HaloError) {}
    public func approveVerification() async throws(HaloError) {}
    public func declineVerification() async throws(HaloError) {}
    public func cancelVerification() async throws(HaloError) {}
}
