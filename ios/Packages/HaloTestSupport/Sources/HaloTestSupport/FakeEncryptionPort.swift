import Foundation
import HaloDomain
import HaloFoundation
import Synchronization

/// An in-memory `EncryptionPort`: an account either has a recovery key or not, and recovering with it verifies the device.
public final class FakeEncryptionPort: EncryptionPort {
    private struct State {
        var status: EncryptionStatus
        var key: String?
        var nextError: HaloError?
        var continuations: [UUID: AsyncStream<EncryptionStatus>.Continuation] = [:]
    }

    private let state: Mutex<State>

    /// - Parameter recoveryKey: the account's recovery key, or `nil` if recovery isn't set up.
    public init(recoveryKey: String?, verified: Bool = false) {
        let recovery: RecoveryState = recoveryKey == nil ? .disabled : (verified ? .enabled : .incomplete)
        state = Mutex(State(status: EncryptionStatus(verification: verified ? .verified : .unverified, recovery: recovery), key: recoveryKey))
    }

    public var status: EncryptionStatus { state.withLock { $0.status } }
    public func failNext(with error: HaloError) { state.withLock { $0.nextError = error } }

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

    private func publish(_ status: EncryptionStatus) {
        for continuation in state.withLock({ Array($0.continuations.values) }) { continuation.yield(status) }
    }
}
