import Foundation
import HaloDomain
import HaloFoundation
import MatrixRustSDK
import Synchronization

/// `EncryptionPort` over the SDK `Encryption` object (docs/features/ENCRYPTION_AND_DEVICES.md). The recovery key only
/// passes through: it is never stored or logged here.
public final class MatrixEncryptionPort: EncryptionPort {
    private struct State {
        var verification: HaloDomain.VerificationState = .unknown
        var recovery: HaloDomain.RecoveryState = .unknown
        var continuations: [UUID: AsyncStream<EncryptionStatus>.Continuation] = [:]
        var handles: [TaskHandle] = []
    }

    private let session: MatrixSessionPort
    private let state = Mutex(State())

    public init(session: MatrixSessionPort) { self.session = session }

    public func statuses() -> AsyncStream<EncryptionStatus> {
        let (stream, continuation) = AsyncStream<EncryptionStatus>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        state.withLock { $0.continuations[id] = continuation }
        continuation.onTermination = { [weak self] _ in self?.state.withLock { _ = $0.continuations.removeValue(forKey: id) } }
        // Subscribe to the SDK on first use and read the current values; a failure (no session) ends the stream.
        Task { [weak self] in
            guard let self else { return }
            do { try await self.observe() } catch { continuation.finish() }
        }
        return stream
    }

    public func recover(recoveryKey: String) async throws(HaloError) {
        let encryption = try await session.encryption()
        do { try await encryption.recover(recoveryKey: recoveryKey) } catch { throw ErrorMapper.map(error) }
        refresh(encryption)
    }

    public func enableRecovery() async throws(HaloError) -> String {
        let encryption = try await session.encryption()
        do {
            await encryption.waitForE2eeInitializationTasks()
            let key = try await encryption.enableRecovery(
                waitForBackupsToUpload: false, key: nil, progressListener: NoProgress())
            refresh(encryption)
            return key
        } catch { throw ErrorMapper.map(error) }
    }

    // MARK: Internals

    private func observe() async throws(HaloError) {
        let encryption = try await session.encryption()
        let subscribed = state.withLock { !$0.handles.isEmpty }
        if !subscribed {
            let handles = [
                encryption.verificationStateListener(listener: VerificationListener { [weak self] sdkState in
                    self?.update { $0.verification = Self.map(sdkState) }
                }),
                encryption.recoveryStateListener(listener: RecoveryListener { [weak self] sdkState in
                    self?.update { $0.recovery = Self.map(sdkState) }
                }),
            ]
            state.withLock { $0.handles = handles }
        }
        refresh(encryption)
    }

    private func refresh(_ encryption: Encryption) {
        let verification = Self.map(encryption.verificationState())
        let recovery = Self.map(encryption.recoveryState())
        update { state in
            state.verification = verification
            state.recovery = recovery
        }
    }

    private func update(_ change: (inout State) -> Void) {
        let (status, continuations) = state.withLock { state -> (EncryptionStatus, [AsyncStream<EncryptionStatus>.Continuation]) in
            change(&state)
            return (EncryptionStatus(verification: state.verification, recovery: state.recovery), Array(state.continuations.values))
        }
        for continuation in continuations { continuation.yield(status) }
    }

    static func map(_ state: MatrixRustSDK.VerificationState) -> HaloDomain.VerificationState {
        switch state {
        case .unknown: .unknown
        case .verified: .verified
        case .unverified: .unverified
        }
    }

    static func map(_ state: MatrixRustSDK.RecoveryState) -> HaloDomain.RecoveryState {
        switch state {
        case .unknown: .unknown
        case .enabled: .enabled
        case .disabled: .disabled
        case .incomplete: .incomplete
        }
    }
}

private final class VerificationListener: VerificationStateListener {
    private let handler: @Sendable (MatrixRustSDK.VerificationState) -> Void
    init(_ handler: @escaping @Sendable (MatrixRustSDK.VerificationState) -> Void) { self.handler = handler }
    func onUpdate(status: MatrixRustSDK.VerificationState) { handler(status) }
}

private final class RecoveryListener: RecoveryStateListener {
    private let handler: @Sendable (MatrixRustSDK.RecoveryState) -> Void
    init(_ handler: @escaping @Sendable (MatrixRustSDK.RecoveryState) -> Void) { self.handler = handler }
    func onUpdate(status: MatrixRustSDK.RecoveryState) { handler(status) }
}

private final class NoProgress: EnableRecoveryProgressListener {
    func onUpdate(status: EnableRecoveryProgress) {}
}
