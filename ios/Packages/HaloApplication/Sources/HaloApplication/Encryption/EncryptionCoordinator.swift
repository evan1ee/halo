import HaloDomain
import HaloFoundation

/// Follows the device's encryption status while a session is ready and runs recovery-key entry
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
    }

    public private(set) var snapshot = Snapshot(status: .unknown, recovery: .idle) {
        didSet { if snapshot != oldValue { broadcaster.publish(snapshot) } }
    }

    private let port: any EncryptionPort
    private let session: SessionCoordinator
    private var broadcaster = SnapshotBroadcaster<Snapshot>()
    private var sessionTask: Task<Void, Never>?
    private var portTask: Task<Void, Never>?

    public init(port: any EncryptionPort, session: SessionCoordinator) {
        self.port = port
        self.session = session
    }

    deinit {
        sessionTask?.cancel()
        portTask?.cancel()
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

    // MARK: Private

    private func sessionReady(_ ready: Bool) {
        portTask?.cancel()
        portTask = nil
        guard ready else {
            snapshot = Snapshot(status: .unknown, recovery: .idle)
            return
        }
        let statuses = port.statuses()
        portTask = Task { [weak self] in
            for await status in statuses { await self?.statusChanged(status) }
        }
    }

    private func statusChanged(_ status: EncryptionStatus) {
        snapshot.status = status
    }
}
