import Foundation
import HaloDomain
import HaloFoundation

/// Sign-in, session restore and sign-out (docs/features/AUTHENTICATION.md §6,
/// docs/architecture/SYSTEM_DESIGN.md §3). Owns the persisted session in the Keychain.
///
/// M0 scope: native password login (D64), restore, logout, SDK-originated token refreshes and
/// logouts. Re-authentication after a soft logout and OIDC arrive with M1/M5.
public actor SessionCoordinator {
    public enum State: Sendable, Equatable {
        case launching
        /// No session. `failure` explains why, if the last attempt failed.
        case signedOut(failure: HaloError?)
        case discovering
        case choosingMethod(ServerDetails, failure: HaloError?)
        case authenticating(ServerDetails)
        case restoring
        /// The stored session couldn't be restored for a reason that may pass (Keychain locked,
        /// storage error). The session is kept; `retryRestore()` tries again.
        case restoreFailed(HaloError)
        case ready(UserID)
        /// The server rejected the token; local data is kept (AUTHENTICATION FR-9).
        case softLoggedOut(UserID)
        case signingOut
    }

    public private(set) var state: State = .launching {
        didSet { if state != oldValue { broadcaster.publish(state) } }
    }

    /// The last failure of work the user didn't start (persisting refreshed tokens). Shown as a
    /// banner by the UI; cleared by the next successful write.
    public private(set) var lastBackgroundFailure: HaloError?

    private let port: any SessionPort
    private let keychain: any KeychainPort
    private let deviceDisplayName: String
    private var beforeSignOut: (@Sendable () async -> Void)?
    private var broadcaster = SnapshotBroadcaster<State>()
    private var updatesTask: Task<Void, Never>?

    /// How long looking up a homeserver may take. Without a limit a host that never answers (for example `localhost:8008` over
    /// HTTPS against a plain-HTTP server) leaves the sign-in screen spinning forever.
    private let discoveryTimeout: Duration

    public init(port: any SessionPort, keychain: any KeychainPort, deviceDisplayName: String = "Halo (iPhone)", discoveryTimeout: Duration = .seconds(20)) {
        self.discoveryTimeout = discoveryTimeout
        self.port = port
        self.keychain = keychain
        self.deviceDisplayName = deviceDisplayName
    }

    deinit {
        updatesTask?.cancel()
    }

    /// Work to do while the session is still valid, right before signing out (removing the pusher). It must not throw.
    public func setBeforeSignOut(_ hook: @escaping @Sendable () async -> Void) { beforeSignOut = hook }

    /// The current state, then its changes. Latest value wins: a subscriber that reads slowly may
    /// skip intermediate states, never the newest one (CONCURRENCY §3).
    public func states() -> AsyncStream<State> {
        broadcaster.subscribe(current: state)
    }

    /// Restores the stored session, if any. Call once at launch.
    public func start() async {
        guard state == .launching else { return }
        await restoreStoredSession()
    }

    public func retryRestore() async {
        guard case .restoreFailed = state else { return }
        await restoreStoredSession()
    }

    /// Looks up the homeserver for a server name, URL or user ID (AUTHENTICATION FR-1, FR-2, FR-5).
    public func discover(server: String) async {
        switch state {
        case .signedOut, .choosingMethod: break
        default: return
        }
        let server = server.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !server.isEmpty else {
            state = .signedOut(failure: .invalidInput("SERVER_EMPTY"))
            return
        }
        state = .discovering
        do {
            let details = try await withTimeout { () async throws(HaloError) -> ServerDetails in try await self.port.loginDetails(server: server) }
            if !details.supportsNativeSlidingSync {
                state = .signedOut(failure: .unsupported("NO_SLIDING_SYNC"))
            } else if !details.supportsPassword && !details.supportsOIDC {
                state = .signedOut(failure: .unsupported("NO_LOGIN_METHOD"))
            } else {
                state = .choosingMethod(details, failure: nil)
            }
        } catch {
            state = .signedOut(failure: error)
        }
    }

    /// Runs `operation`, giving up with a retryable network error after `discoveryTimeout`.
    private func withTimeout(_ operation: @escaping @Sendable () async throws(HaloError) -> ServerDetails) async throws(HaloError) -> ServerDetails {
        let timeout = discoveryTimeout
        do {
            return try await withThrowingTaskGroup(of: ServerDetails.self) { group in
                group.addTask { try await operation() }
                group.addTask {
                    try await Task.sleep(for: timeout)
                    throw HaloError.network(retryable: true)
                }
                defer { group.cancelAll() }
                guard let first = try await group.next() else { throw HaloError.internal(code: "DISCOVERY") }
                return first
            }
        } catch let error as HaloError {
            throw error
        } catch {
            throw HaloError.internal(code: "DISCOVERY")
        }
    }

    /// Native password login (D64). Ignored unless a server has been chosen, so a second tap while
    /// signing in does nothing (AUTHENTICATION §10).
    public func loginPassword(username: String, password: String) async {
        guard case .choosingMethod(let details, _) = state else { return }
        guard details.supportsPassword else {
            state = .choosingMethod(details, failure: .unsupported("NO_PASSWORD_LOGIN"))
            return
        }
        state = .authenticating(details)
        let credentials = PasswordCredentials(username: username, password: password, deviceDisplayName: deviceDisplayName)
        let session: StoredSession
        do {
            session = try await port.loginPassword(credentials, on: details)
        } catch {
            state = .choosingMethod(details, failure: error)
            return
        }
        do {
            try await persist(session)
        } catch {
            // Without a persisted session the app couldn't restore this device after a relaunch,
            // so sign it out again instead of leaving an orphaned device on the server. Best-effort:
            // the user already sees the persistence failure, a logout failure adds nothing.
            try? await port.logout()
            state = .choosingMethod(details, failure: error)
            return
        }
        becomeReady(session.userID)
    }

    /// Signs out on the server and removes the stored session (AUTHENTICATION FR-8). Local data is
    /// removed even if the server can't be reached; that failure is reported in `.signedOut`.
    public func logout() async {
        switch state {
        case .ready, .softLoggedOut, .restoreFailed: break
        default: return
        }
        state = .signingOut
        stopObservingUpdates()
        var failure: HaloError?
        await beforeSignOut?()
        do { try await port.logout() } catch { failure = error }
        do { try await keychain.delete(.session) } catch { failure = failure ?? error }
        state = .signedOut(failure: failure)
    }

    // MARK: Private

    private func restoreStoredSession() async {
        state = .restoring
        let session: StoredSession
        do {
            guard let data = try await keychain.read(.session) else {
                state = .signedOut(failure: nil)
                return
            }
            session = try decode(data)
        } catch {
            state = error == .storage(.corrupted) ? .signedOut(failure: error) : .restoreFailed(error)
            return
        }
        do {
            try await port.restore(session)
            becomeReady(session.userID)
        } catch .unauthorized(soft: true) {
            state = .softLoggedOut(session.userID)
        } catch .unauthorized(soft: false) {
            await forgetSession(reason: .unauthorized(soft: false))
        } catch {
            state = .restoreFailed(error)
        }
    }

    private func becomeReady(_ user: UserID) {
        state = .ready(user)
        let updates = port.sessionUpdates()
        updatesTask?.cancel()
        updatesTask = Task { [weak self] in
            for await event in updates {
                await self?.handle(event)
            }
        }
    }

    private func handle(_ event: SessionEvent) async {
        switch event {
        case .tokensRefreshed(let session):
            do {
                try await persist(session)
                lastBackgroundFailure = nil
            } catch {
                lastBackgroundFailure = error
            }
        case .softLoggedOut:
            if case .ready(let user) = state { state = .softLoggedOut(user) }
        case .loggedOut:
            stopObservingUpdates()
            await forgetSession(reason: .unauthorized(soft: false))
        }
    }

    private func forgetSession(reason: HaloError) async {
        do {
            try await keychain.delete(.session)
            state = .signedOut(failure: reason)
        } catch {
            state = .signedOut(failure: error)
        }
    }

    private func stopObservingUpdates() {
        updatesTask?.cancel()
        updatesTask = nil
    }

    private func persist(_ session: StoredSession) async throws(HaloError) {
        let data: Data
        do { data = try JSONEncoder().encode(session) } catch { throw .internal(code: "SESSION_ENCODE") }
        try await keychain.write(data, for: .session)
    }

    private func decode(_ data: Data) throws(HaloError) -> StoredSession {
        do { return try JSONDecoder().decode(StoredSession.self, from: data) } catch { throw .storage(.corrupted) }
    }
}
