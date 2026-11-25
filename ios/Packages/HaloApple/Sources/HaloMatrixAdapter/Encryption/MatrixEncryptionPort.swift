import Foundation
import HaloDomain
import HaloFoundation
import MatrixRustSDK
import Synchronization

/// `EncryptionPort` over the SDK `Encryption` and `SessionVerificationController` objects (docs/features/ENCRYPTION_AND_DEVICES.md).
/// The recovery key only passes through: it is never stored or logged here.
public final class MatrixEncryptionPort: EncryptionPort {
    private struct State {
        var verification: HaloDomain.VerificationState = .unknown
        var recovery: HaloDomain.RecoveryState = .unknown
        var backup: HaloDomain.BackupState = .unknown
        var pendingReset: IdentityResetHandle?
        var phase: SessionVerificationPhase = .idle
        var continuations: [UUID: AsyncStream<EncryptionStatus>.Continuation] = [:]
        var phaseContinuations: [UUID: AsyncStream<SessionVerificationPhase>.Continuation] = [:]
        var handles: [TaskHandle] = []
        var controller: SessionVerificationController?
        var delegate: VerificationDelegate?
    }

    private let session: MatrixSessionPort
    private let state = Mutex(State())

    public init(session: MatrixSessionPort) { self.session = session }

    deinit {
        state.withLock { state in
            for handle in state.handles { handle.cancel() }
            state.handles.removeAll()
            state.controller?.setDelegate(delegate: nil)
        }
    }

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

    public func verificationPhases() -> AsyncStream<SessionVerificationPhase> {
        let (stream, continuation) = AsyncStream<SessionVerificationPhase>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        let current = state.withLock { state in
            state.phaseContinuations[id] = continuation
            return state.phase
        }
        continuation.yield(current)
        continuation.onTermination = { [weak self] _ in self?.state.withLock { _ = $0.phaseContinuations.removeValue(forKey: id) } }
        Task { [weak self] in
            guard let self else { return }
            _ = try? await self.ensureVerificationController()  // best-effort: a cancelled or acknowledged verification step; the flow reports its own state
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

    public func resetRecovery() async throws(HaloError) -> String {
        let encryption = try await session.encryption()
        do {
            await encryption.waitForE2eeInitializationTasks()
            let key = try await encryption.resetRecoveryKey()
            refresh(encryption)
            return key
        } catch { throw ErrorMapper.map(error) }
    }

    public func prepareIdentityReset() async throws(HaloError) -> IdentityResetRequirement {
        let encryption = try await session.encryption()
        do {
            await encryption.waitForE2eeInitializationTasks()
            guard let handle = try await encryption.resetIdentity() else { return .nothingToReset }
            let previous = state.withLock { state -> IdentityResetHandle? in
                defer { state.pendingReset = handle }
                return state.pendingReset
            }
            await previous?.cancel()
            switch handle.authType() {
            case .uiaa: return .password
            case .oAuth(let info): return .approveInBrowser(approvalURL: info.approvalUrl)
            }
        } catch { throw ErrorMapper.map(error) }
    }

    public func resetIdentity(password: String?) async throws(HaloError) -> String {
        let encryption = try await session.encryption()
        let pending = state.withLock { state -> IdentityResetHandle? in
            defer { state.pendingReset = nil }
            return state.pendingReset
        }
        do {
            if let pending {
                switch pending.authType() {
                case .uiaa(let info):
                    guard let password, !password.isEmpty else { throw HaloError.invalidInput("PASSWORD") }
                    let user = try await session.signedInClient().userId()
                    try await pending.reset(auth: .password(passwordDetails: AuthDataPasswordDetails(identifier: user, password: password, session: info.session)))
                case .oAuth(let info):
                    try await pending.reset(auth: .oAuth(session: info.session))
                }
            }
            // The reset deleted secret storage and the recovery key: make a new one (it also covers the backup).
            let key = try await encryption.enableRecovery(waitForBackupsToUpload: false, key: nil, progressListener: NoProgress())
            refresh(encryption)
            return key
        } catch let error as HaloError { throw error } catch { throw ErrorMapper.map(error) }
    }

    public func cancelIdentityReset() async {
        let pending = state.withLock { state -> IdentityResetHandle? in
            defer { state.pendingReset = nil }
            return state.pendingReset
        }
        await pending?.cancel()
    }

    public func requestDeviceVerification() async throws(HaloError) {
        let encryption = try await session.encryption()
        await encryption.waitForE2eeInitializationTasks()
        let controller = try await ensureVerificationController()
        do {
            updatePhase(.waitingForOtherDevice)
            try await controller.requestDeviceVerification()
        } catch {
            let mapped = ErrorMapper.map(error)
            updatePhase(.failed(mapped.code))
            throw mapped
        }
    }

    public func acceptVerificationRequest() async throws(HaloError) {
        let controller = try await ensureVerificationController()
        do {
            try await controller.acceptVerificationRequest()
            updatePhase(.startingSAS)
            try await controller.startSasVerification()
        } catch {
            let mapped = ErrorMapper.map(error)
            updatePhase(.failed(mapped.code))
            throw mapped
        }
    }

    public func approveVerification() async throws(HaloError) {
        let controller = try await ensureVerificationController()
        do {
            updatePhase(.waitingForPartnerConfirmation)
            try await controller.approveVerification()
        } catch {
            let mapped = ErrorMapper.map(error)
            updatePhase(.failed(mapped.code))
            throw mapped
        }
    }

    public func declineVerification() async throws(HaloError) {
        let controller = try await ensureVerificationController()
        do {
            try await controller.declineVerification()
            updatePhase(.cancelled(reason: "The emojis didn't match."))
        } catch {
            let mapped = ErrorMapper.map(error)
            updatePhase(.failed(mapped.code))
            throw mapped
        }
    }

    public func cancelVerification() async throws(HaloError) {
        let controller = try await ensureVerificationController()
        do {
            try await controller.cancelVerification()
            updatePhase(.idle)
        } catch {
            updatePhase(.idle)
            throw ErrorMapper.map(error)
        }
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
                encryption.backupStateListener(listener: BackupListener { [weak self] sdkState in
                    self?.update { $0.backup = Self.map(sdkState) }
                }),
            ]
            state.withLock { $0.handles = handles }
        }
        refresh(encryption)
    }

    private func ensureVerificationController() async throws(HaloError) -> SessionVerificationController {
        if let existing = state.withLock({ $0.controller }) { return existing }
        let controller = try await session.sessionVerificationController()
        let delegate = VerificationDelegate(
            onRequest: { [weak self] details in
                // Acknowledge the incoming request off the callback thread (AGENTS.md §8), then publish `.incomingRequest`.
                Task { [weak self] in
                    guard let self else { return }
                    try? await controller.acknowledgeVerificationRequest(  // best-effort: a cancelled or acknowledged verification step; the flow reports its own state
                        senderId: details.senderProfile.userId, flowId: details.flowId)
                    self.updatePhase(.incomingRequest(VerificationRequest(
                        senderID: details.senderProfile.userId,
                        flowID: details.flowId,
                        deviceID: details.deviceId,
                        deviceDisplayName: details.deviceDisplayName)))
                }
            },
            onAccept: { [weak self] in
                Task { [weak self] in
                    guard let self else { return }
                    self.updatePhase(.startingSAS)
                    try? await controller.startSasVerification()  // best-effort: a cancelled or acknowledged verification step; the flow reports its own state
                }
            },
            onStartSAS: { [weak self] in
                self?.updatePhaseIfNotComparing(.startingSAS)
            },
            onData: { [weak self] phase in
                self?.updatePhase(phase)
            },
            onFail: { [weak self] in
                self?.updatePhase(.failed("VERIFICATION_FAILED"))
            },
            onCancel: { [weak self] in
                let reason = controller.sasCancelInfo()?.reason ?? controller.requestCancelInfo()?.reason
                self?.updatePhase(.cancelled(reason: reason))
            },
            onFinish: { [weak self] in
                guard let self else { return }
                self.updatePhase(.verified)
                Task { [weak self] in
                    guard let self, let encryption = try? await self.session.encryption() else { return }  // best-effort: a cancelled or acknowledged verification step; the flow reports its own state
                    self.refresh(encryption)
                }
            }
        )
        controller.setDelegate(delegate: delegate)
        state.withLock { state in
            state.controller = controller
            state.delegate = delegate
        }
        return controller
    }

    private func refresh(_ encryption: Encryption) {
        let verification = Self.map(encryption.verificationState())
        let recovery = Self.map(encryption.recoveryState())
        let backup = Self.map(encryption.backupState())
        update { state in
            state.verification = verification
            state.recovery = recovery
            state.backup = backup
        }
    }

    private func update(_ change: (inout State) -> Void) {
        let (status, continuations) = state.withLock { state -> (EncryptionStatus, [AsyncStream<EncryptionStatus>.Continuation]) in
            change(&state)
            return (EncryptionStatus(verification: state.verification, recovery: state.recovery, backup: state.backup), Array(state.continuations.values))
        }
        for continuation in continuations { continuation.yield(status) }
    }

    private func updatePhase(_ phase: SessionVerificationPhase) {
        let continuations = state.withLock { state -> [AsyncStream<SessionVerificationPhase>.Continuation] in
            state.phase = phase
            return Array(state.phaseContinuations.values)
        }
        for continuation in continuations { continuation.yield(phase) }
    }

    private func updatePhaseIfNotComparing(_ phase: SessionVerificationPhase) {
        let continuations = state.withLock { state -> [AsyncStream<SessionVerificationPhase>.Continuation]? in
            switch state.phase {
            case .comparingEmojis, .comparingDecimals, .waitingForPartnerConfirmation, .verified:
                return nil
            default:
                state.phase = phase
                return Array(state.phaseContinuations.values)
            }
        }
        guard let continuations else { return }
        for continuation in continuations { continuation.yield(phase) }
    }

    static func map(_ state: MatrixRustSDK.VerificationState) -> HaloDomain.VerificationState {
        switch state {
        case .unknown: .unknown
        case .verified: .verified
        case .unverified: .unverified
        }
    }

    static func map(_ state: MatrixRustSDK.BackupState) -> HaloDomain.BackupState {
        switch state {
        case .unknown: .off
        case .creating, .enabling, .disabling: .working
        case .resuming, .enabled, .downloading: .on
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

private final class BackupListener: BackupStateListener {
    private let handler: @Sendable (MatrixRustSDK.BackupState) -> Void
    init(_ handler: @escaping @Sendable (MatrixRustSDK.BackupState) -> Void) { self.handler = handler }
    func onUpdate(status: MatrixRustSDK.BackupState) { handler(status) }
}

private final class NoProgress: EnableRecoveryProgressListener {
    func onUpdate(status: EnableRecoveryProgress) {}
}

/// Maps `SessionVerificationControllerDelegate` callbacks immediately to domain types without blocking the FFI thread (AGENTS.md §8).
private final class VerificationDelegate: SessionVerificationControllerDelegate {
    private let onRequest: @Sendable (SessionVerificationRequestDetails) -> Void
    private let onAccept: @Sendable () -> Void
    private let onStartSAS: @Sendable () -> Void
    private let onData: @Sendable (SessionVerificationPhase) -> Void
    private let onFail: @Sendable () -> Void
    private let onCancel: @Sendable () -> Void
    private let onFinish: @Sendable () -> Void

    init(
        onRequest: @escaping @Sendable (SessionVerificationRequestDetails) -> Void,
        onAccept: @escaping @Sendable () -> Void,
        onStartSAS: @escaping @Sendable () -> Void,
        onData: @escaping @Sendable (SessionVerificationPhase) -> Void,
        onFail: @escaping @Sendable () -> Void,
        onCancel: @escaping @Sendable () -> Void,
        onFinish: @escaping @Sendable () -> Void
    ) {
        self.onRequest = onRequest
        self.onAccept = onAccept
        self.onStartSAS = onStartSAS
        self.onData = onData
        self.onFail = onFail
        self.onCancel = onCancel
        self.onFinish = onFinish
    }

    func didReceiveVerificationRequest(details: SessionVerificationRequestDetails) {
        onRequest(details)
    }

    func didAcceptVerificationRequest() {
        onAccept()
    }

    func didStartSasVerification() {
        onStartSAS()
    }

    func didReceiveVerificationData(data: SessionVerificationData) {
        // Map upstream FFI objects (`SessionVerificationEmoji`) immediately on callback entry (AGENTS.md §8).
        switch data {
        case .emojis(let emojis, _):
            let mapped = emojis.map { VerificationEmoji(symbol: $0.symbol(), description: $0.description()) }
            onData(.comparingEmojis(mapped))
        case .decimals(let values):
            onData(.comparingDecimals(values))
        }
    }

    func didFail() {
        onFail()
    }

    func didCancel() {
        onCancel()
    }

    func didFinish() {
        onFinish()
    }
}
