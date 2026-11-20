import HaloApplication
import HaloDomain
import HaloFoundation
import Observation

/// Why setting up a recovery key failed, in words for the user.
public struct RecoverySetupFailure: Error, Sendable, Equatable {
    public let text: String
    /// A key backup already exists on the server: the user may replace it (the old backup is lost).
    public let backupExists: Bool
}

/// Offers recovery-key entry while this device is unverified (docs/features/ENCRYPTION_AND_DEVICES.md FR-3, FR-4).
/// The key lives in `key` only until it is submitted, then the field is cleared; it is never stored.
@MainActor @Observable
public final class RecoveryViewModel {
    /// Show the "verify this device" banner.
    public private(set) var needsRecovery = false
    public private(set) var isWorking = false
    public private(set) var errorMessage: String?
    /// Set when recovery succeeded, so the sheet can close.
    public private(set) var isVerified = false
    /// Plain-language state for Settings → Security.
    public private(set) var deviceStatus = "Checking…"
    public private(set) var recoveryStatus = "Checking…"

    public var key = ""

    private let coordinator: EncryptionCoordinator
    private var observation: Task<Void, Never>?

    public init(coordinator: EncryptionCoordinator) { self.coordinator = coordinator }

    isolated deinit { observation?.cancel() }

    public func start() async {
        guard observation == nil else { return }
        await coordinator.begin()
        let snapshots = await coordinator.snapshots()
        observation = Task { [weak self] in
            for await snapshot in snapshots { self?.apply(snapshot) }
        }
    }

    /// Settings → Security: "Set up recovery key" is offered only while the account has none.
    public var canSetUpRecovery: Bool { recoveryStatus == "Not set up" }

    /// Creates the recovery key; `nil` (with `errorMessage` set) when it failed. The caller shows the key once and drops it.
    public func setUpRecovery() async -> Result<String, RecoverySetupFailure> {
        do {
            return .success(try await coordinator.enableRecovery())
        } catch {
            if error.code.hasSuffix("RECOVERY_BACKUP_EXISTS") {
                return .failure(RecoverySetupFailure(
                    text: "A key backup from another session already exists on your account. A new recovery key replaces it: messages that are only in the old backup can't be restored afterwards.",
                    backupExists: true))
            }
            return .failure(RecoverySetupFailure(text: "The recovery key couldn't be created (\(error.code)).", backupExists: false))
        }
    }

    /// Replaces the existing backup with a new recovery key; call only after the user confirmed.
    public func replaceRecovery() async -> Result<String, RecoverySetupFailure> {
        do {
            let key = try await coordinator.replaceRecovery()
            // A reset doesn't import the new secrets into this device: use the new key at once so the device ends up verified.
            await coordinator.recover(recoveryKey: key)
            return .success(key)
        } catch {
            return .failure(RecoverySetupFailure(text: "The recovery key couldn't be created (\(error.code)).", backupExists: false))
        }
    }

    public func submit() async {
        let entered = key
        key = ""
        await coordinator.recover(recoveryKey: entered)
    }

    func apply(_ snapshot: EncryptionCoordinator.Snapshot) {
        needsRecovery = snapshot.status.needsRecovery
        deviceStatus = switch snapshot.status.verification {
        case .verified: "Verified"
        case .unverified: "Not verified"
        case .unknown: "Checking…"
        }
        recoveryStatus = switch snapshot.status.recovery {
        case .enabled: "On"
        case .incomplete: "On, this device needs the key"
        case .disabled: "Not set up"
        case .unknown: "Checking…"
        }
        isVerified = snapshot.status.verification == .verified
        switch snapshot.recovery {
        case .idle:
            isWorking = false
            errorMessage = nil
        case .working:
            isWorking = true
            errorMessage = nil
        case .failed(let error):
            isWorking = false
            errorMessage = Self.message(for: error)
        }
    }

    static func message(for error: HaloError) -> String {
        switch error {
        case .invalidInput("RECOVERY_KEY"): "That recovery key doesn't match. Check it and try again."
        case .network: "Can't reach the server. Check the connection and try again."
        default: "The device couldn't be verified (\(error.code))."
        }
    }
}
