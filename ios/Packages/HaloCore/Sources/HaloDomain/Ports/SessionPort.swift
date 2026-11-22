import Foundation
import HaloFoundation

/// Authentication and the session lifecycle (docs/matrix/PORTS_CONTRACT.md §2). Implemented by
/// `HaloMatrixAdapter`; faked in `HaloTestSupport`.
public protocol SessionPort: Sendable {
    /// Resolves a server name, homeserver URL or user ID to a homeserver and its login methods.
    /// Throws `.network`, `.notFound` (no homeserver there) or `.invalidInput`.
    func loginDetails(server: String) async throws(HaloError) -> ServerDetails

    /// Signs in with a password on a server returned by `loginDetails`. Wrong credentials throw
    /// `.unauthorized(soft: false)`. The returned session must be persisted by the caller.
    func loginPassword(_ credentials: PasswordCredentials, on server: ServerDetails) async throws(HaloError) -> StoredSession

    /// Starts an OIDC / OAuth 2.0 login flow on `server` and returns the authorization URL to open in
    /// `ASWebAuthenticationSession` (AUTHENTICATION FR-3, M5).
    func oauthURL(on server: ServerDetails) async throws(HaloError) -> URL

    /// Completes an OIDC / OAuth 2.0 login flow with the redirect callback URL returned by `ASWebAuthenticationSession`.
    /// The returned session must be persisted by the caller (AUTHENTICATION FR-3, M5).
    func completeOAuth(callbackURL: URL) async throws(HaloError) -> StoredSession

    /// Cancels an in-progress OIDC / OAuth 2.0 login flow and cleans up its temporary store (AUTHENTICATION FR-3, M5).
    func abortOAuth() async

    /// Restores a persisted session without user interaction; works offline. A rejected session
    /// throws `.unauthorized(soft:)`.
    func restore(_ session: StoredSession) async throws(HaloError)

    /// Signs out on the server and deletes the adapter's per-account stores (AUTHENTICATION FR-8).
    /// Local data is removed even if the server can't be reached; that case still throws `.network`.
    func logout() async throws(HaloError)

    /// SDK-originated session changes. Snapshot semantics are not needed: every event matters, so
    /// the stream is lossless (CONCURRENCY §3).
    func sessionUpdates() -> AsyncStream<SessionEvent>
}

extension SessionPort {
    public func oauthURL(on server: ServerDetails) async throws(HaloError) -> URL {
        throw .unsupported("NO_OIDC_LOGIN")
    }

    public func completeOAuth(callbackURL: URL) async throws(HaloError) -> StoredSession {
        throw .unsupported("NO_OIDC_LOGIN")
    }

    public func abortOAuth() async {}
}
