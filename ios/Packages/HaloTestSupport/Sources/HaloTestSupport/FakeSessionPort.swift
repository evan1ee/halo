import Foundation
import HaloDomain
import HaloFoundation
import Synchronization

/// An in-memory homeserver directory and account table implementing `SessionPort`.
public final class FakeSessionPort: SessionPort {
    public struct Account: Sendable {
        public let localpart: String
        public let password: String
        public init(localpart: String, password: String) {
            self.localpart = localpart
            self.password = password
        }
    }

    private struct State {
        var servers: [String: ServerDetails] = [:]
        var accounts: [String: Account] = [:]
        var revokedTokens: Set<Data> = []
        var softLoggedOutTokens: Set<Data> = []
        var issuedTokens = 0
        var nextError: [String: HaloError] = [:]
        var continuations: [UUID: AsyncStream<SessionEvent>.Continuation] = [:]
        var calls: [String] = []
    }

    private let state = Mutex(State())

    public init() {}

    // MARK: Scripting

    /// Makes `server` (a server name, URL or user ID) resolve to `details`.
    public func addServer(_ server: String, _ details: ServerDetails) { state.withLock { $0.servers[server] = details } }
    public func addAccount(_ account: Account) { state.withLock { $0.accounts[account.localpart] = account } }
    /// The next call of `method` (`loginDetails`, `loginPassword`, `restore`, `logout`) throws `error`.
    public func failNext(_ method: String, with error: HaloError) { state.withLock { $0.nextError[method] = error } }
    /// The server rejects this session from now on, as after "sign out all other devices".
    public func revoke(_ session: StoredSession, soft: Bool) {
        state.withLock { state in
            if soft { _ = state.softLoggedOutTokens.insert(session.payload) } else { _ = state.revokedTokens.insert(session.payload) }
        }
    }
    /// Delivers an SDK-originated event to every `sessionUpdates()` subscriber.
    public func send(_ event: SessionEvent) {
        for continuation in state.withLock({ Array($0.continuations.values) }) { continuation.yield(event) }
    }
    /// The port methods called so far, in order.
    public var calls: [String] { state.withLock { $0.calls } }

    // MARK: SessionPort

    public func loginDetails(server: String) async throws(HaloError) -> ServerDetails {
        try begin("loginDetails")
        guard let details = state.withLock({ $0.servers[server] }) else { throw .notFound }
        return details
    }

    public func loginPassword(_ credentials: PasswordCredentials, on server: ServerDetails) async throws(HaloError) -> StoredSession {
        try begin("loginPassword")
        guard server.supportsPassword else { throw .unsupported("NO_PASSWORD_LOGIN") }
        let token: Data? = state.withLock { state in
            guard state.accounts[credentials.username]?.password == credentials.password else { return nil }
            state.issuedTokens += 1
            return Data("token-\(state.issuedTokens)".utf8)
        }
        guard let token else { throw .unauthorized(soft: false) }
        let host = server.homeserverURL.host() ?? "localhost"
        return StoredSession(
            userID: try UserID("@\(credentials.username):\(host)"),
            deviceID: try DeviceID("FAKEDEVICE\(token.count)"),
            payload: token
        )
    }

    public func restore(_ session: StoredSession) async throws(HaloError) {
        try begin("restore")
        let (revoked, soft) = state.withLock { ($0.revokedTokens.contains(session.payload), $0.softLoggedOutTokens.contains(session.payload)) }
        if revoked { throw .unauthorized(soft: false) }
        if soft { throw .unauthorized(soft: true) }
    }

    public func logout() async throws(HaloError) {
        try begin("logout")
    }

    public func sessionUpdates() -> AsyncStream<SessionEvent> {
        let (stream, continuation) = AsyncStream<SessionEvent>.makeStream()
        let id = UUID()
        state.withLock { $0.continuations[id] = continuation }
        continuation.onTermination = { [weak self] _ in self?.state.withLock { _ = $0.continuations.removeValue(forKey: id) } }
        return stream
    }

    private func begin(_ method: String) throws(HaloError) {
        let error: HaloError? = state.withLock { state in
            state.calls.append(method)
            return state.nextError.removeValue(forKey: method)
        }
        if let error { throw error }
    }
}
