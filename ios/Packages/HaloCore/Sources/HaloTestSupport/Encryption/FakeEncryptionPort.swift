import Foundation
import HaloDomain
import HaloFoundation
import Synchronization

/// An in-memory `EncryptionPort`: an account either has a recovery key or not, and recovering with it or completing
/// SAS verification verifies the device.
public final class FakeEncryptionPort: EncryptionPort {
    private struct State {
        var status: EncryptionStatus
        var phase: SessionVerificationPhase = .idle
        var key: String?
        var nextError: HaloError?
        var continuations: [UUID: AsyncStream<EncryptionStatus>.Continuation] = [:]
        var phaseContinuations: [UUID: AsyncStream<SessionVerificationPhase>.Continuation] = [:]
    }

    private let state: Mutex<State>

    /// - Parameter recoveryKey: the account's recovery key, or `nil` if recovery isn't set up.
    public init(recoveryKey: String?, verified: Bool = false) {
        let recovery: RecoveryState = recoveryKey == nil ? .disabled : (verified ? .enabled : .incomplete)
        state = Mutex(State(status: EncryptionStatus(verification: verified ? .verified : .unverified, recovery: recovery), key: recoveryKey))
    }

    public var status: EncryptionStatus { state.withLock { $0.status } }
    public var verificationPhase: SessionVerificationPhase { state.withLock { $0.phase } }
    public func failNext(with error: HaloError) { state.withLock { $0.nextError = error } }

    /// Simulates an external SAS verification event (such as an incoming request or emoji list from a peer device).
    public func simulateVerificationPhase(_ phase: SessionVerificationPhase) {
        let (status, phaseConts, statusConts) = state.withLock { state -> (EncryptionStatus?, [AsyncStream<SessionVerificationPhase>.Continuation], [AsyncStream<EncryptionStatus>.Continuation]) in
            state.phase = phase
            var updatedStatus: EncryptionStatus?
            if phase == .verified {
                let recovery: RecoveryState = state.key == nil ? .disabled : .enabled
                state.status = EncryptionStatus(verification: .verified, recovery: recovery)
                updatedStatus = state.status
            }
            return (updatedStatus, Array(state.phaseContinuations.values), Array(state.continuations.values))
        }
        for continuation in phaseConts { continuation.yield(phase) }
        if let status {
            for continuation in statusConts { continuation.yield(status) }
        }
    }

    public func statuses() -> AsyncStream<EncryptionStatus> {
        let (stream, continuation) = AsyncStream<EncryptionStatus>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        let current = state.withLock { state in
            state.continuations[id] = continuation
            return state.status
        }
        continuation.yield(current)
        continuation.onTermination = { [weak self] _ in self?.state.withLock { _ = $0.continuations.removeValue(forKey: id) } }
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
        return stream
    }

    public func recover(recoveryKey: String) async throws(HaloError) {
        let result: Result<EncryptionStatus, HaloError> = state.withLock { state in
            if let error = state.nextError {
                state.nextError = nil
                return .failure(error)
            }
            guard let key = state.key, key == recoveryKey else { return .failure(.invalidInput("RECOVERY_KEY")) }
            state.status = EncryptionStatus(verification: .verified, recovery: .enabled)
            return .success(state.status)
        }
        publish(try result.get())
    }

    public func enableRecovery() async throws(HaloError) -> String {
        let key = "FAKE-RECOVERY-KEY-\(UUID().uuidString)"
        let status = state.withLock { state in
            state.key = key
            state.status = EncryptionStatus(verification: .verified, recovery: .enabled)
            return state.status
        }
        publish(status)
        return key
    }

    public func resetRecovery() async throws(HaloError) -> String {
        let key = "FAKE-RECOVERY-KEY-\(UUID().uuidString)"
        let result: Result<EncryptionStatus, HaloError> = state.withLock { state in
            if let error = state.nextError {
                state.nextError = nil
                return .failure(error)
            }
            state.key = key
            // Match the real SDK (`F-FFI-19`): `resetRecoveryKey` leaves the creating device in `.incomplete`
            // until `recover(recoveryKey:)` imports the new secrets.
            state.status = EncryptionStatus(verification: .unverified, recovery: .incomplete)
            return .success(state.status)
        }
        publish(try result.get())
        return key
    }

    public func requestDeviceVerification() async throws(HaloError) {
        if let error = state.withLock({ state -> HaloError? in
            defer { state.nextError = nil }
            return state.nextError
        }) { throw error }
        simulateVerificationPhase(.waitingForOtherDevice)
    }

    public func acceptVerificationRequest() async throws(HaloError) {
        if let error = state.withLock({ state -> HaloError? in
            defer { state.nextError = nil }
            return state.nextError
        }) { throw error }
        simulateVerificationPhase(.startingSAS)
    }

    public func approveVerification() async throws(HaloError) {
        if let error = state.withLock({ state -> HaloError? in
            defer { state.nextError = nil }
            return state.nextError
        }) { throw error }
        simulateVerificationPhase(.waitingForPartnerConfirmation)
    }

    public func declineVerification() async throws(HaloError) {
        if let error = state.withLock({ state -> HaloError? in
            defer { state.nextError = nil }
            return state.nextError
        }) { throw error }
        simulateVerificationPhase(.cancelled(reason: "The emojis didn't match."))
    }

    public func cancelVerification() async throws(HaloError) {
        if let error = state.withLock({ state -> HaloError? in
            defer { state.nextError = nil }
            return state.nextError
        }) { throw error }
        simulateVerificationPhase(.idle)
    }

    private func publish(_ status: EncryptionStatus) {
        for continuation in state.withLock({ Array($0.continuations.values) }) { continuation.yield(status) }
    }
}
