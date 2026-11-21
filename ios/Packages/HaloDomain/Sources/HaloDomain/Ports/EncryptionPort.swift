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
