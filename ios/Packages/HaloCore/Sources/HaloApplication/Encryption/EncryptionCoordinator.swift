import HaloDomain
import HaloFoundation

/// Follows the device's encryption status while a session is ready and runs recovery-key entry and SAS device verification
/// (docs/features/ENCRYPTION_AND_DEVICES.md §5–6). The recovery key is passed through, never kept.
public actor EncryptionCoordinator {
    public enum Recovery: Sendable, Equatable {
        case idle
        case working
        /// The last attempt failed; `.invalidInput("RECOVERY_KEY")` means the key was wrong.
        case failed(HaloError)
    }

    public struct Snapshot: Sendable, Equatable {
        public var status: EncryptionStatus
        public var recovery: Recovery
        public var verificationPhase: SessionVerificationPhase

        public init(status: EncryptionStatus, recovery: Recovery, verificationPhase: SessionVerificationPhase = .idle) {
            self.status = status
            self.recovery = recovery
            self.verificationPhase = verificationPhase
        }
    }

    public private(set) var snapshot = Snapshot(status: .unknown, recovery: .idle, verificationPhase: .idle) {
        didSet { if snapshot != oldValue { broadcaster.publish(snapshot) } }
    }

    private let port: any EncryptionPort
    private let session: SessionCoordinator
    private var broadcaster = SnapshotBroadcaster<Snapshot>()
    private var sessionTask: Task<Void, Never>?
    private var portTask: Task<Void, Never>?
    private var phaseTask: Task<Void, Never>?

    public init(port: any EncryptionPort, session: SessionCoordinator) {
        self.port = port
        self.session = session
    }

    deinit {
        sessionTask?.cancel()
        portTask?.cancel()
        phaseTask?.cancel()
    }

    public func snapshots() -> AsyncStream<Snapshot> { broadcaster.subscribe(current: snapshot) }

    /// Starts following the session. Call once at launch.
    public func begin() async {
        guard sessionTask == nil else { return }
        let states = await session.states()
        sessionTask = Task { [weak self] in
            for await state in states {
                var ready = false
                if case .ready = state { ready = true }
                await self?.sessionReady(ready)
            }
        }
    }

    /// Verifies this device with the user's recovery key (AC-E2EE-2). Ignored while an attempt runs.
    public func recover(recoveryKey: String) async {
        guard snapshot.recovery != .working else { return }
        let trimmed = recoveryKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            snapshot.recovery = .failed(.invalidInput("RECOVERY_KEY"))
            return
        }
        snapshot.recovery = .working
        do {
            try await port.recover(recoveryKey: trimmed)
            snapshot.recovery = .idle
        } catch {
            snapshot.recovery = .failed(error)
        }
    }

    /// Sets up secret storage and backup and returns the new recovery key, to be shown once and not kept (FR-4).
    public func enableRecovery() async throws(HaloError) -> String {
        guard snapshot.recovery != .working else { throw .invalidInput("RECOVERY_BUSY") }
        snapshot.recovery = .working
        defer { if snapshot.recovery == .working { snapshot.recovery = .idle } }
        return try await port.enableRecovery()
    }

    /// Replaces an existing key backup with a new recovery key. Only after the user confirmed the loss of the old backup.
    public func replaceRecovery() async throws(HaloError) -> String {
        guard snapshot.recovery != .working else { throw .invalidInput("RECOVERY_BUSY") }
        snapshot.recovery = .working
        defer { if snapshot.recovery == .working { snapshot.recovery = .idle } }
        return try await port.resetRecovery()
    }

    /// What a reset of the end-to-end identity needs from the person (FR-8). Nothing is changed yet.
    public func prepareIdentityReset() async throws(HaloError) -> IdentityResetRequirement {
        guard snapshot.recovery != .working else { throw .invalidInput("RECOVERY_BUSY") }
        return try await port.prepareIdentityReset()
    }

    /// Resets the identity and returns the new recovery key, to be shown once and not kept (FR-8, AC-SEC-3).
    public func resetIdentity(password: String?) async throws(HaloError) -> String {
        guard snapshot.recovery != .working else { throw .invalidInput("RECOVERY_BUSY") }
        snapshot.recovery = .working
        defer { if snapshot.recovery == .working { snapshot.recovery = .idle } }
        return try await port.resetIdentity(password: password)
    }

    public func cancelIdentityReset() async { await port.cancelIdentityReset() }

    /// Requests interactive SAS (emoji / decimal) verification with the user's other signed-in devices (FR-2).
    public func requestDeviceVerification() async {
        do {
            try await port.requestDeviceVerification()
        } catch {
            snapshot.verificationPhase = .failed(error.code)
        }
    }

    /// Accepts an incoming SAS verification request from another device (FR-2).
    public func acceptVerificationRequest() async {
        do {
            try await port.acceptVerificationRequest()
        } catch {
            snapshot.verificationPhase = .failed(error.code)
        }
    }

    /// Confirms that the SAS emojis or decimal numbers match on both devices (FR-2).
    public func approveVerification() async {
        do {
            try await port.approveVerification()
        } catch {
            snapshot.verificationPhase = .failed(error.code)
        }
    }

    /// Rejects a mismatched SAS comparison (FR-2).
    public func declineVerification() async {
        do {
            try await port.declineVerification()
        } catch {
            snapshot.verificationPhase = .failed(error.code)
        }
    }

    /// Cancels an active SAS verification flow and resets to `.idle` (FR-2).
    public func cancelVerification() async {
        try? await port.cancelVerification()  // best-effort: a cancelled or acknowledged verification step; the flow reports its own state
        snapshot.verificationPhase = .idle
    }

    // MARK: Private

    private func sessionReady(_ ready: Bool) {
        portTask?.cancel()
        portTask = nil
        phaseTask?.cancel()
        phaseTask = nil
        guard ready else {
            snapshot = Snapshot(status: .unknown, recovery: .idle, verificationPhase: .idle)
            return
        }
        let statuses = port.statuses()
        portTask = Task { [weak self] in
            for await status in statuses { await self?.statusChanged(status) }
        }
        let phases = port.verificationPhases()
        phaseTask = Task { [weak self] in
            for await phase in phases { await self?.phaseChanged(phase) }
        }
    }

    private func statusChanged(_ status: EncryptionStatus) {
        snapshot.status = status
    }

    private func phaseChanged(_ phase: SessionVerificationPhase) {
        snapshot.verificationPhase = phase
    }
}
