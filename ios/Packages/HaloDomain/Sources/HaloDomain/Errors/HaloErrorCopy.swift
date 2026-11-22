import HaloFoundation

/// Maps every `HaloError` case to a short, plain, actionable user-facing sentence (`docs/design/DESIGN_SYSTEM.md` §12, UX-15).
///
/// Technical codes and adapter strings stay in `HaloLog` and Diagnostics; they never reach user alerts.
public enum HaloErrorCopy {
    public static func message(for error: HaloError) -> String {
        switch error {
        case .network(retryable: true):
            return "Couldn't reach your homeserver. Check your connection and try again."
        case .network(retryable: false):
            return "The homeserver couldn't complete this request. Try again later."
        case .unauthorized(soft: true):
            return "Your session expired. Sign in again to continue."
        case .unauthorized(soft: false):
            return "That username or password didn't work. Check them and try again."
        case .forbidden:
            return "You don't have permission to do that."
        case .notFound:
            return "That item could not be found."
        case .crypto(.missingKeys):
            return "This message couldn't be decrypted yet. Verify this device to unlock older keys."
        case .crypto(.unverifiedDevice):
            return "Verify this device first to continue."
        case .crypto(.noBackup):
            return "Key backup isn't set up on this account yet."
        case .crypto(.verificationFailed):
            return "Verification didn't match. Try again."
        case .invalidInput:
            return "Check what you entered and try again."
        case .unsupported:
            return "This action isn't supported on your homeserver."
        case .storage(.unavailable):
            return "Unlock your device and try again."
        case .storage(.corrupted):
            return "Local data couldn't be read. Sign out and sign in again if this keeps happening."
        case .storage(.migrationFailed):
            return "Halo couldn't update its local storage. Reinstall or sign in again."
        case .cancelled:
            return "Cancelled."
        case .internal:
            return "Something went wrong. Try again."
        }
    }
}
