/// The only error type that crosses a port (docs/architecture/ERROR_HANDLING.md §1).
///
/// Upstream errors are mapped to it exactly once, in the adapter that received them. Associated
/// strings are stable reason codes chosen by Halo, never user content or server text, so a
/// `HaloError` is always safe to log.
public enum HaloError: Error, Sendable, Equatable {
    /// Offline, timeout, 5xx or rate limiting. `retryable` says whether retrying the same request can succeed.
    case network(retryable: Bool)
    /// The access token was rejected. `soft` keeps local data and asks for re-authentication.
    case unauthorized(soft: Bool)
    /// The server refused the action (power levels, ACLs).
    case forbidden
    /// The room, event or user doesn't exist (any more).
    case notFound
    case crypto(CryptoFailure)
    /// Input failed validation; the associated value is a reason code such as `USER_ID_SIGIL`.
    case invalidInput(String)
    /// The server lacks a capability Halo needs; the associated value is a reason code such as `NO_SLIDING_SYNC`.
    case unsupported(String)
    case storage(StorageFailure)
    case cancelled
    /// A bug. Never shown raw to users.
    case `internal`(code: String)

    /// A stable identifier for logs and diagnostics (e.g. `NET_RETRYABLE`, `AUTH_SOFT_LOGOUT`).
    public var code: String {
        switch self {
        case .network(let retryable): retryable ? "NET_RETRYABLE" : "NET_FAILED"
        case .unauthorized(let soft): soft ? "AUTH_SOFT_LOGOUT" : "AUTH_UNAUTHORIZED"
        case .forbidden: "FORBIDDEN"
        case .notFound: "NOT_FOUND"
        case .crypto(let failure): "CRYPTO_\(failure.code)"
        case .invalidInput(let reason): "INVALID_INPUT_\(reason)"
        case .unsupported(let reason): "UNSUPPORTED_\(reason)"
        case .storage(let failure): "STORAGE_\(failure.code)"
        case .cancelled: "CANCELLED"
        case .internal(let code): "INTERNAL_\(code)"
        }
    }

    /// Whether background work may retry with backoff (ERROR_HANDLING §2 rule 4).
    public var isRetryable: Bool {
        if case .network(retryable: true) = self { return true }
        return false
    }
}

public enum CryptoFailure: Sendable, Equatable {
    case missingKeys
    case unverifiedDevice
    case noBackup
    case verificationFailed

    var code: String {
        switch self {
        case .missingKeys: "MISSING_KEYS"
        case .unverifiedDevice: "UNVERIFIED_DEVICE"
        case .noBackup: "NO_BACKUP"
        case .verificationFailed: "VERIFICATION_FAILED"
        }
    }
}

public enum StorageFailure: Sendable, Equatable {
    /// Not readable right now, e.g. the Keychain before the first unlock after a reboot.
    case unavailable
    case corrupted
    case migrationFailed

    var code: String {
        switch self {
        case .unavailable: "UNAVAILABLE"
        case .corrupted: "CORRUPTED"
        case .migrationFailed: "MIGRATION_FAILED"
        }
    }
}
