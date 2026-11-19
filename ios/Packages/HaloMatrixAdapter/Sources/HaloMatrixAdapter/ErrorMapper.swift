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
        case let error as URLError: return map(error)
        default: return .internal(code: "SDK_UNMAPPED")
        }
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

    static func map(_ error: ClientBuildError) -> HaloError {
        switch error {
        case .InvalidServerName: .invalidInput("SERVER_NAME")
        case .ServerUnreachable: .network(retryable: true)
        case .WellKnownLookupDisabled, .WellKnownLookupFailed, .WellKnownDeserializationError: .notFound
        case .SlidingSync, .SlidingSyncVersion: .unsupported("NO_SLIDING_SYNC")
        case .Sdk, .EventCache, .Generic: .internal(code: "SDK_BUILD")
        }
    }

    static func map(_ error: URLError) -> HaloError {
        switch error.code {
        case .cancelled: .cancelled
        default: .network(retryable: true)
        }
    }
}
