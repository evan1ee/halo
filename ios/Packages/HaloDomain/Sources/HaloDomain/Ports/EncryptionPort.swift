import HaloFoundation

/// End-to-end encryption state and recovery (docs/matrix/PORTS_CONTRACT.md §2, docs/features/ENCRYPTION_AND_DEVICES.md).
/// Implemented by `HaloMatrixAdapter`; faked in `HaloTestSupport`. Keys never cross this port: the recovery key is the
/// user's input (`recover`) or the one-time output of `enableRecovery`, and callers must not store or log it
/// (docs/security/SECURITY.md §3). M1 surface: recovery-key flows; QR/emoji verification follows.
public protocol EncryptionPort: Sendable {
    /// The current status, then every change. Snapshot semantics: the latest value wins (CONCURRENCY §3).
    func statuses() -> AsyncStream<EncryptionStatus>

    /// Restores secrets and key backup with the user's recovery key, which verifies this device. A key that
    /// doesn't match throws `.invalidInput("RECOVERY_KEY")`.
    func recover(recoveryKey: String) async throws(HaloError)

    /// Creates secret storage and backup and returns the new recovery key, to be shown to the user once.
    func enableRecovery() async throws(HaloError) -> String
}
