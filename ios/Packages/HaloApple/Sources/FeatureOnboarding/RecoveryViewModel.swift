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
    /// Whether message keys are backed up on the server, for Settings → Security.
    public private(set) var backupStatus = "Checking…"
    /// Current interactive SAS (emoji / decimal) device verification phase (ENCRYPTION_AND_DEVICES FR-2).
    public private(set) var verificationPhase: SessionVerificationPhase = .idle

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

    /// Lost the recovery key and every other device (FR-8): says what the person must give to reset the identity.
    public func prepareIdentityReset() async -> Result<IdentityResetRequirement, RecoverySetupFailure> {
        do { return .success(try await coordinator.prepareIdentityReset()) } catch {
            return .failure(RecoverySetupFailure(text: Self.resetMessage(for: error), backupExists: false))
        }
    }

    /// Resets the identity and returns the new recovery key, to be shown once. Call only after the person confirmed what is lost.
    public func resetIdentity(password: String?) async -> Result<String, RecoverySetupFailure> {
        do { return .success(try await coordinator.resetIdentity(password: password)) } catch {
            return .failure(RecoverySetupFailure(text: Self.resetMessage(for: error), backupExists: false))
        }
    }

    public func cancelIdentityReset() async { await coordinator.cancelIdentityReset() }

    static func resetMessage(for error: HaloError) -> String {
        switch error {
        case .invalidInput("PASSWORD"): "Enter your account password."
        case .unauthorized: "That password doesn't match, or the approval wasn't completed. Nothing was changed."
        case .network: "Can't reach the server. Nothing was changed; try again."
        default: "The identity couldn't be reset (\(error.code)). Try again."
        }
    }

    public func submit() async {
        let entered = key
        key = ""
        await coordinator.recover(recoveryKey: entered)
    }

    /// Starts SAS (emoji / decimal) verification with another signed-in device (ENCRYPTION_AND_DEVICES FR-2).
    public func requestDeviceVerification() async {
        await coordinator.requestDeviceVerification()
    }

    /// Accepts an incoming SAS verification request from another session (FR-2).
    public func acceptVerificationRequest() async {
        await coordinator.acceptVerificationRequest()
    }

    /// Confirms that the SAS emojis or decimal numbers match on both screens (FR-2).
    public func approveVerification() async {
        await coordinator.approveVerification()
    }

    /// Rejects a mismatched SAS comparison (FR-2).
    public func declineVerification() async {
        await coordinator.declineVerification()
    }

    /// Cancels an active SAS verification flow and resets to `.idle` (FR-2).
    public func cancelVerification() async {
        await coordinator.cancelVerification()
    }

    func apply(_ snapshot: EncryptionCoordinator.Snapshot) {
        let verified = snapshot.status.verification == .verified || snapshot.verificationPhase == .verified
        needsRecovery = snapshot.status.needsRecovery && !verified
        verificationPhase = snapshot.verificationPhase
        deviceStatus = switch snapshot.status.verification {
        case .verified: "Verified"
        case .unverified: verified ? "Verified" : "Not verified"
        case .unknown: "Checking…"
        }
        backupStatus = switch snapshot.status.backup {
        case .on: "On"
        case .off: "Off"
        case .working: "Updating…"
        case .unknown: "Checking…"
        }
        recoveryStatus = switch snapshot.status.recovery {
        case .enabled: "On"
        case .incomplete: "On, this device needs the key"
        case .disabled: "Not set up"
        case .unknown: "Checking…"
        }
        isVerified = verified
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
