import Foundation
import HaloFoundation
import MatrixRustSDK

/// Maps every upstream error to `HaloError` exactly once (AGENTS.md §10, docs/architecture/ERROR_HANDLING.md).
/// Reason codes are chosen here; server text and SDK messages are never copied into a `HaloError`.
enum ErrorMapper {
    static func map(_ error: any Error) -> HaloError {
        switch error {
        case let error as HaloError: return error
        case is CancellationError: return .cancelled
        case let error as ClientError: return map(error)
        case let error as ClientBuildError: return map(error)
        case let error as RecoveryError: return map(error)
        case let error as URLError: return map(error)
        default: return .internal(code: "SDK_UNMAPPED")
        }
    }

    /// For the login call only: Synapse answers wrong credentials with `M_FORBIDDEN` (found by
    /// `SessionPortContract` against infra/dev), which anywhere else means "not allowed".
    static func mapLogin(_ error: any Error) -> HaloError {
        let mapped = map(error)
        return mapped == .forbidden ? .unauthorized(soft: false) : mapped
    }

    /// For local-echo send-queue actions (`retrySend`, `abortSend`, R-27): `TimelineError::EventNotInTimeline` crosses
    /// FFI as `ClientError.Generic(msg: "Event not found in timeline: ...")`, which maps to `.notFound`; every other
    /// error keeps its real cause via `map(_:)`.
    static func mapLocalEcho(_ error: any Error) -> HaloError {
        if case let ClientError.Generic(msg, _) = error, msg.contains("Event not found in timeline") {
            return .notFound
        }
        return map(error)
    }

    /// For opening a timeline around an event: a missing event crosses FFI as a generic error naming `EventNotFound`.
    static func mapFocus(_ error: any Error) -> HaloError {
        if case let ClientError.Generic(msg, details) = error {
            let text = msg + (details ?? "")
            if text.contains("EventNotFound") || text.contains("M_NOT_FOUND") { return .notFound }
            if text.contains("M_FORBIDDEN") { return .forbidden }
        }
        return map(error)
    }

    static func map(_ error: ClientError) -> HaloError {
        switch error {
        case .MatrixApi(let kind, _, _, _): return map(kind)
        case .Generic: return .internal(code: "SDK_GENERIC")
        case .ContentScanner: return .internal(code: "SDK_CONTENT_SCANNER")
        }
    }

    static func map(_ kind: ErrorKind) -> HaloError {
        switch kind {
        case .forbidden: .forbidden
        case .notFound: .notFound
        case .unknownToken(let softLogout): .unauthorized(soft: softLogout)
        case .missingToken: .unauthorized(soft: false)
        case .limitExceeded: .network(retryable: true)
        default: .internal(code: "MATRIX_API")
        }
    }

    /// A key that doesn't unlock secret storage is the user's input problem; the rest is mapped by cause.
    static func map(_ error: RecoveryError) -> HaloError {
        switch error {
        case .SecretStorage: .invalidInput("RECOVERY_KEY")
        case .Client(let source): map(source)
        case .BackupExistsOnServer: .internal(code: "RECOVERY_BACKUP_EXISTS")
        case .Import: .crypto(.verificationFailed)
        }
    }

    static func map(_ error: ClientBuildError) -> HaloError {
        switch error {
        case .InvalidServerName: .invalidInput("SERVER_NAME")
        case .ServerUnreachable: .network(retryable: true)
        case .WellKnownLookupDisabled, .WellKnownLookupFailed, .WellKnownDeserializationError: .notFound
        case .SlidingSync, .SlidingSyncVersion: .unsupported("NO_SLIDING_SYNC")
        case .Sdk(let message), .EventCache(let message), .Generic(let message): buildFailure(message)
        }
    }

    /// A store the SDK can't open. The SDK gives the reason only as text, so the damage is recognised by what it says (found
    /// by `StoreRecoveryContractTests`: garbage files → "disk I/O error", a wrong passphrase → "store cipher"); anything else
    /// stays an internal error that may pass. The text is never copied into the error.
    static func buildFailure(_ message: String) -> HaloError {
        let text = message.lowercased()
        let damage = ["store cipher", "aead", "not a database", "malformed", "corrupt", "disk i/o error", "disk image"]
        return damage.contains(where: text.contains) ? .storage(.corrupted) : .internal(code: "SDK_BUILD")
    }

    static func map(_ error: URLError) -> HaloError {
        switch error.code {
        case .cancelled: .cancelled
        default: .network(retryable: true)
        }
    }
}
