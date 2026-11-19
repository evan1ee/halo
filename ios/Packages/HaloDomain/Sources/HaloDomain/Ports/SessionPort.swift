import HaloFoundation

/// Authentication and the session lifecycle (docs/matrix/PORTS_CONTRACT.md §2). Implemented by
/// `HaloMatrixAdapter`; faked in `HaloTestSupport`.
///
/// M0 surface: discovery and native password login (D64). OIDC (`oauthURL`, `completeOAuth`) is
/// added in M5 as a MINOR port change.
public protocol SessionPort: Sendable {
    /// Resolves a server name, homeserver URL or user ID to a homeserver and its login methods.
    /// Throws `.network`, `.notFound` (no homeserver there) or `.invalidInput`.
    func loginDetails(server: String) async throws(HaloError) -> ServerDetails

    /// Signs in with a password on a server returned by `loginDetails`. Wrong credentials throw
    /// `.unauthorized(soft: false)`. The returned session must be persisted by the caller.
    func loginPassword(_ credentials: PasswordCredentials, on server: ServerDetails) async throws(HaloError) -> StoredSession

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
