import Foundation
import HaloDomain
import HaloFoundation
import MatrixRustSDK
import Synchronization

/// `SessionPort` over the SDK `Client` (docs/matrix/SDK_INTEGRATION.md §3–4, AUTHENTICATION §7).
///
/// The persisted `StoredSession.payload` is a JSON `SessionPayload`: the SDK session, the per-login
/// store directory and the SDK store passphrase. It lives only in the Keychain (written by the caller).
public actor MatrixSessionPort: SessionPort {
    struct SessionPayload: Codable {
        var accessToken: String
        var refreshToken: String?
        var userID: String
        var deviceID: String
        var homeserverURL: String
        var oauthData: String?
        var storeID: String
        var passphrase: String
    }

    private let baseDirectory: URL
    private let holderName: String
    private let sendsMessages: Bool
    private let lightweightRuntime: Bool
    private let enablesSlidingSync: Bool
    private let readStoredSession: (@Sendable () -> StoredSession?)?
    private let persistRefreshedSession: (@Sendable (StoredSession) -> Void)?
    private let initialisePlatform: @Sendable (Bool) throws(HaloError) -> Void
    private var client: Client?
    private var syncTask: Task<Void, Never>?
    private var stoppingTask: Task<Void, Never>?
    private var statusObservers: [UUID: @Sendable (SyncStatus) -> Void] = [:]
    private var changeObservers: [UUID: AsyncStream<SyncChange>.Continuation] = [:]
    private var storeID: String?
    private var delegate: RefreshDelegate?
    /// Receives SDK-wide `M_UNKNOWN_TOKEN` notifications and turns them into `.loggedOut` / `.softLoggedOut` (R-10).
    private var authDelegate: AuthDelegate?
    private var authDelegateHandle: TaskHandle?
    private var sessionGeneration: UInt64 = 0
    private var reportedAuthErrorGeneration: UInt64?
    /// Single-flight guard for `restore(_:)` so concurrent callers never build two `Client`s on the same store (R-12).
    private var inFlightRestore: (payload: Data, generation: UInt64, task: Task<Void, any Error>)?
    /// Set when a room's send queue reported an error (which disables that queue); the next successful sync re-enables them.
    private var sendQueueErrors: SendQueueErrors?
    private var sendQueueErrorsHandle: TaskHandle?
    private var searchBackfillHandle: TaskHandle?
    private var events: [UUID: AsyncStream<SessionEvent>.Continuation] = [:]
    /// Pending OIDC / OAuth 2.0 login flow awaiting the redirect callback URL (AUTHENTICATION FR-3).
    private var pendingOAuth: (client: Client, storeID: String, passphrase: String, authData: OAuthAuthorizationData)?

    public static let oauthRedirectURI = "one.mbm.halo:/oauth/callback"
    public static let oauthClientURI = "https://halo.mbm.one"

    /// SDK media cache retention defaults (D55, V-MEDIA-1): 1 GiB total cache, 50 MiB max single file,
    /// 30-day unaccessed expiry, daily cleanup. Applied to main-app sessions only (not the NSE).
    static let defaultMediaRetentionPolicy = MediaRetentionPolicy(
        maxCacheSize: 1_073_741_824,
        maxFileSize: 52_428_800,
        lastAccessExpiry: 30 * 86_400,
        cleanupFrequency: 86_400
    )

    /// - Parameters:
    ///   - baseDirectory: where per-login SDK stores live (the App Group container in the app).
    ///   - holderName: this process's name for the SDK's cross-process lock ("app" or "nse").
    ///   - sendsMessages: whether this process owns the unsent-message queues (the app does; the extension must not).
    ///   - lightweightRuntime: use the SDK's lightweight runtime (the extension does).
    ///   - enablesSlidingSync: configure native sliding sync on the SDK client. The app uses classic `/sync` (`.none`,
    ///     D74), while the NSE calls `NotificationClient.getNotification` which runs a short-lived sliding sync first.
    ///   - readStoredSession: optional synchronous Keychain reader so `ClientSessionDelegate.retrieveSessionFromKeychain`
    ///     sees the current session before the first save in this process and across app/NSE token rotations (R-11).
    ///   - persistRefreshedSession: optional synchronous Keychain writer so processes without a `SessionCoordinator`
    ///     subscriber (the NSE) persist rotated refresh tokens immediately before exiting (R-11).
    public init(
        baseDirectory: URL,
        holderName: String = "app",
        sendsMessages: Bool = true,
        lightweightRuntime: Bool = false,
        enablesSlidingSync: Bool = false,
        readStoredSession: (@Sendable () -> StoredSession?)? = nil,
        persistRefreshedSession: (@Sendable (StoredSession) -> Void)? = nil
    ) {
        self.init(
            baseDirectory: baseDirectory, holderName: holderName, sendsMessages: sendsMessages,
            lightweightRuntime: lightweightRuntime, enablesSlidingSync: enablesSlidingSync,
            readStoredSession: readStoredSession, persistRefreshedSession: persistRefreshedSession,
            initialisePlatform: MatrixBootstrap.initialise(lightweightRuntime:))
    }

    init(
        baseDirectory: URL, holderName: String = "app", sendsMessages: Bool = true,
        lightweightRuntime: Bool = false,
        enablesSlidingSync: Bool = false,
        readStoredSession: (@Sendable () -> StoredSession?)? = nil,
        persistRefreshedSession: (@Sendable (StoredSession) -> Void)? = nil,
        initialisePlatform: @escaping @Sendable (Bool) throws(HaloError) -> Void
    ) {
        self.baseDirectory = baseDirectory
        self.holderName = holderName
        self.sendsMessages = sendsMessages
        self.lightweightRuntime = lightweightRuntime
        self.enablesSlidingSync = enablesSlidingSync
        self.readStoredSession = readStoredSession
        self.persistRefreshedSession = persistRefreshedSession
        self.initialisePlatform = initialisePlatform
    }

    // MARK: SessionPort

    public func loginDetails(server: String) async throws(HaloError) -> ServerDetails {
        let trimmed = server.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw .invalidInput("SERVER_EMPTY") }
        try initialisePlatform(lightweightRuntime)
        do {
            let probe = try await ClientBuilder()
                .serverNameOrHomeserverUrl(serverNameOrUrl: trimmed)
                .slidingSyncVersionBuilder(versionBuilder: .none)
                .build()
            let details = await probe.homeserverLoginDetails()
            guard let url = URL(string: probe.homeserver()) else { throw HaloError.internal(code: "HOMESERVER_URL") }
            return ServerDetails(
                homeserverURL: url,
                supportsPassword: details.supportsPasswordLogin(),
                supportsOIDC: details.supportsOauthLogin(),
                supportsNativeSlidingSync: details.slidingSyncVersion() == .native
            )
        } catch { throw ErrorMapper.map(error) }
    }

    public func loginPassword(
        _ credentials: PasswordCredentials, on server: ServerDetails
    ) async throws(HaloError) -> StoredSession {
        try initialisePlatform(lightweightRuntime)
        let newStoreID = UUID().uuidString
        let passphrase = Self.randomPassphrase()
        do {
            let client = try await makeClient(
                homeserver: server.homeserverURL.absoluteString, storeID: newStoreID, passphrase: passphrase)
            do {
                try await client.login(
                    username: credentials.username, password: credentials.password,
                    initialDeviceName: credentials.deviceDisplayName, deviceId: nil)
            } catch {
                Self.removeStore(baseDirectory, newStoreID)
                throw ErrorMapper.mapLogin(error)
            }
            let stored = try Self.stored(from: client.session(), storeID: newStoreID, passphrase: passphrase)
            sessionGeneration &+= 1
            await adopt(client, storeID: newStoreID, session: try client.session(), generation: sessionGeneration)
            return stored
        } catch let error as HaloError {
            throw error
        } catch {
            Self.removeStore(baseDirectory, newStoreID)
            throw ErrorMapper.map(error)
        }
    }

    public func oauthURL(on server: ServerDetails) async throws(HaloError) -> URL {
        guard server.supportsOIDC else { throw .unsupported("NO_OIDC_LOGIN") }
        try initialisePlatform(lightweightRuntime)
        await abortOAuth()
        let newStoreID = UUID().uuidString
        let passphrase = Self.randomPassphrase()
        do {
            let client = try await makeClient(
                homeserver: server.homeserverURL.absoluteString, storeID: newStoreID, passphrase: passphrase)
            let config = OAuthConfiguration(
                clientName: "Halo",
                redirectUri: Self.oauthRedirectURI,
                clientUri: Self.oauthClientURI,
                logoUri: nil,
                tosUri: nil,
                policyUri: nil,
                staticRegistrations: [:])
            let authData = try await client.urlForOauth(
                oauthConfiguration: config,
                prompt: nil,
                loginHint: nil,
                deviceId: nil,
                additionalScopes: nil)
            guard let url = URL(string: authData.loginUrl()) else {
                Self.removeStore(baseDirectory, newStoreID)
                throw HaloError.internal(code: "OAUTH_URL")
            }
            pendingOAuth = (client, newStoreID, passphrase, authData)
            return url
        } catch let error as HaloError {
            throw error
        } catch {
            Self.removeStore(baseDirectory, newStoreID)
            throw ErrorMapper.map(error)
        }
    }

    public func completeOAuth(callbackURL: URL) async throws(HaloError) -> StoredSession {
        guard let pending = pendingOAuth else { throw .invalidInput("NO_PENDING_OAUTH") }
        pendingOAuth = nil
        do {
            try await pending.client.loginWithOauthCallback(callbackUrl: callbackURL.absoluteString)
            let sdkSession = try pending.client.session()
            let stored = try Self.stored(from: sdkSession, storeID: pending.storeID, passphrase: pending.passphrase)
            sessionGeneration &+= 1
            await adopt(pending.client, storeID: pending.storeID, session: sdkSession, generation: sessionGeneration)
            return stored
        } catch {
            Self.removeStore(baseDirectory, pending.storeID)
            throw ErrorMapper.mapLogin(error)
        }
    }

    public func abortOAuth() async {
        guard let pending = pendingOAuth else { return }
        pendingOAuth = nil
        await pending.client.abortOauthAuth(authorizationData: pending.authData)
        Self.removeStore(baseDirectory, pending.storeID)
    }

    public func restore(_ session: StoredSession) async throws(HaloError) {
        try initialisePlatform(lightweightRuntime)
        if let existing = inFlightRestore, existing.payload == session.payload, existing.generation == sessionGeneration {
            do { try await existing.task.value; return } catch { throw ErrorMapper.map(error) }
        }
        let payload: SessionPayload
        do { payload = try JSONDecoder().decode(SessionPayload.self, from: session.payload) } catch {
            throw .storage(.corrupted)
        }
        sessionGeneration &+= 1
        let generation = sessionGeneration
        let slidingSyncVersion: SlidingSyncVersion = enablesSlidingSync ? .native : .none
        let task = Task<Void, any Error> {
            let sdkSession = Session(
                accessToken: payload.accessToken, refreshToken: payload.refreshToken, userId: payload.userID,
                deviceId: payload.deviceID, homeserverUrl: payload.homeserverURL, oauthData: payload.oauthData,
                slidingSyncVersion: slidingSyncVersion)
            let client = try await self.makeClient(
                homeserver: payload.homeserverURL, storeID: payload.storeID, passphrase: payload.passphrase,
                initialSession: sdkSession)
            try await client.restoreSession(session: sdkSession)
            await self.adopt(client, storeID: payload.storeID, session: sdkSession, generation: generation)
        }
        inFlightRestore = (session.payload, generation, task)
        defer {
            if inFlightRestore?.generation == generation { inFlightRestore = nil }
        }
        do { try await task.value } catch { throw ErrorMapper.map(error) }
    }

    public func logout() async throws(HaloError) {
        sessionGeneration &+= 1
        inFlightRestore = nil
        await abortOAuth()
        let client = self.client
        let storeID = self.storeID
        await stopSync()
        clearClientState()
        var failure: HaloError?
        if let client {
            do { try await client.logout() } catch { failure = ErrorMapper.map(error) }
        }
        if let storeID { Self.removeStore(baseDirectory, storeID) }
        if let failure { throw failure }
    }

    public nonisolated func sessionUpdates() -> AsyncStream<SessionEvent> {
        let (stream, continuation) = AsyncStream<SessionEvent>.makeStream(bufferingPolicy: .unbounded)
        let id = UUID()
        Task { await self.register(continuation, id: id) }
        continuation.onTermination = { [weak self] _ in
            guard let self else { return }
            Task { await self.unregister(id) }
        }
        return stream
    }

    // MARK: Classic sync (V-RS-7 / D73)

    /// The rooms one sync response touched (their ids), so the room list refreshes only those.
    struct SyncChange: Sendable {
        let joined: Set<String>
        let invited: Set<String>
        let left: Set<String>
    }

    /// Starts the classic `/sync` loop (`Client.syncOnceV2`, sliding sync off): the unread evidence is the server's counts
    /// plus the SDK's own, per room. Own loop, not `Client.syncV2`, so errors and backoff are visible: a retryable error (or the SDK's generic
    /// sync error, which is what an unreachable server produces) reports `.offline` and retries; any other ends the loop with `.failed` (`SyncCoordinator` restarts it).
    func startSync() async throws(HaloError) {
        guard let client else { throw .unauthorized(soft: false) }
        guard syncTask == nil else { return }
        // A loop that was stopped may still be inside its long poll; two loops must never overlap.
        let previous = stoppingTask
        let generation = sessionGeneration
        syncTask = Task { [weak self] in
            await previous?.value
            guard !Task.isCancelled else { return }
            await self?.runSync(client, generation: generation)
        }
    }

    /// Cancels the loop and returns once it has ended or after a short grace period: the SDK call in flight is a long
    /// poll (up to 30 s) that may not be interruptible, and a sign-out or a pause must not wait for it. A later `startSync`
    /// waits for the old loop to end before it begins.
    func stopSync() async {
        guard let task = syncTask else { return }
        syncTask = nil
        task.cancel()
        stoppingTask = task
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await task.value }
            group.addTask { try? await Task.sleep(for: .seconds(1)) }
            await group.next()
            group.cancelAll()
        }
    }

    /// The server long-poll. Cancelling the task does not interrupt the SDK call, and `client.logout()` waits for it, so a
    /// short poll bounds how long a sign-out or a restart can wait; the cost is one empty request per interval while the app is open.
    static let longPollMilliseconds: UInt64 = 8_000

    private func runSync(_ client: Client, generation: UInt64) async {
        var backoff = Duration.seconds(1)
        var first = true
        var recovering = false
        while !Task.isCancelled {
            do {
                let response = try await client.syncOnceV2(settings: SyncSettingsV2(timeoutMs: first ? 0 : Self.longPollMilliseconds, fullState: false))
                if Task.isCancelled { return }
                first = false
                backoff = .seconds(1)
                // A recoverable send failure (offline) disables that room's send queue until it is enabled again (SDK
                // `EventSendState.sendingFailed`). The server answers again, so messages that failed meanwhile go out by
                // themselves (MESSAGING FR-3, verified by the `offlineSend` contract test); at most once per sync.
                let queueFailed = sendQueueErrors?.take() == true
                if sendsMessages, recovering || queueFailed { await client.enableAllSendQueues(enable: true) }
                recovering = false
                publish(status: .running)
                publish(change: SyncChange(joined: Set(response.rooms.joined), invited: Set(response.rooms.invited), left: Set(response.rooms.left)))
            } catch {
                if Task.isCancelled { return }
                let mapped = ErrorMapper.map(error)
                if case .unauthorized(let soft) = mapped {
                    // Revoked / soft-logged-out token (R-10): stop sync and notify `SessionCoordinator` instead of
                    // publishing `.failed` (which `SyncCoordinator` would restart in an endless backoff loop).
                    syncTask = nil
                    await handleAuthError(isSoftLogout: soft, generation: generation)
                    return
                }
                // With the server unreachable the SDK's sync fails with a generic error (found by the `offlineSend` contract
                // test), so that one is retried like a network error; everything else (forbidden, unsupported) ends the loop.
                guard mapped.isRetryable || mapped == .internal(code: "SDK_GENERIC") else {
                    publish(status: .failed)
                    syncTask = nil
                    return
                }
                publish(status: .offline)
                recovering = true
                try? await Task.sleep(for: backoff)
                backoff = min(backoff * 2, .seconds(60))
            }
        }
    }

    private func publish(status: SyncStatus) { for observer in statusObservers.values { observer(status) } }
    private func publish(change: SyncChange) { for continuation in changeObservers.values { continuation.yield(change) } }

    /// Reports sync status changes until `cancel` (the returned id) is passed to `unobserveSync`.
    func observeSync(_ onUpdate: @escaping @Sendable (SyncStatus) -> Void) -> UUID {
        let id = UUID()
        statusObservers[id] = onUpdate
        return id
    }

    func unobserveSync(_ id: UUID) { statusObservers[id] = nil }

    /// The rooms each sync response changed, until the stream ends.
    func syncChanges() -> AsyncStream<SyncChange> {
        let (stream, continuation) = AsyncStream<SyncChange>.makeStream(bufferingPolicy: .unbounded)
        let id = UUID()
        changeObservers[id] = continuation
        continuation.onTermination = { [weak self] _ in Task { await self?.dropChangeObserver(id) } }
        return stream
    }

    private func dropChangeObserver(_ id: UUID) { changeObservers[id] = nil }

    /// The SDK room for `id`; `.notFound` if the client doesn't know it.
    func room(_ id: RoomID) async throws(HaloError) -> Room {
        guard let client else { throw .unauthorized(soft: false) }
        do {
            guard let room = try client.getRoom(roomId: id.rawValue) else { throw HaloError.notFound }
            return room
        } catch let error as HaloError { throw error } catch { throw ErrorMapper.map(error) }
    }

    /// Downloads media for a reference made by `TimelineMapper.ref`.
    func mediaData(_ ref: MediaRef, thumbnail: (width: Int, height: Int)?) async throws(HaloError) -> Data {
        guard let client else { throw .unauthorized(soft: false) }
        do {
            let source = try MediaSource.fromJson(json: ref.token)
            if let thumbnail {
                return try await client.getMediaThumbnail(mediaSource: source, width: UInt64(thumbnail.width), height: UInt64(thumbnail.height))
            }
            return try await client.getMediaContent(mediaSource: source)
        } catch { throw ErrorMapper.map(error) }
    }

    /// The signed-in user's Matrix ID, used to tell own reactions from others'.
    func ownUserID() throws(HaloError) -> String {
        guard let client else { throw .unauthorized(soft: false) }
        do { return try client.userId() } catch { throw ErrorMapper.map(error) }
    }

    /// The signed-in SDK client, for ports that need it directly (pushers).
    func signedInClient() throws(HaloError) -> Client {
        guard let client else { throw .unauthorized(soft: false) }
        return client
    }

    /// The SDK's encryption object for the signed-in client.
    func encryption() throws(HaloError) -> Encryption {
        guard let client else { throw .unauthorized(soft: false) }
        return client.encryption()
    }

    /// The SDK's session verification controller for SAS (emoji / decimal) verification (ENCRYPTION_AND_DEVICES FR-2).
    func sessionVerificationController() async throws(HaloError) -> SessionVerificationController {
        guard let client else { throw .unauthorized(soft: false) }
        do { return try await client.getSessionVerificationController() } catch { throw ErrorMapper.map(error) }
    }

    // MARK: Internals

    private func register(_ continuation: AsyncStream<SessionEvent>.Continuation, id: UUID) { events[id] = continuation }
    private func unregister(_ id: UUID) { events[id] = nil }

    private func adopt(_ client: Client, storeID: String, session: Session, generation: UInt64) async {
        // If `logout()` or a newer login/restore superseded this generation while `restoreSession` was in flight,
        // discard the client instead of installing it behind the coordinator's back (R-12).
        guard sessionGeneration == generation else { return }
        // Unsent messages survive an app kill and go out when the network returns (MESSAGING FR-3).
        if sendsMessages {
            await client.enableAllSendQueues(enable: true)
            let errors = SendQueueErrors()
            sendQueueErrorsHandle?.cancel()
            sendQueueErrorsHandle = client.subscribeToSendQueueStatus(listener: errors)
            sendQueueErrors = errors
            searchBackfillHandle?.cancel()
            searchBackfillHandle = client.runSearchBackfill(strategy: .foreground)
            try? await client.setMediaRetentionPolicy(policy: Self.defaultMediaRetentionPolicy)
        }
        authDelegateHandle?.cancel()
        let auth = AuthDelegate { [weak self] isSoftLogout in
            Task { await self?.handleAuthError(isSoftLogout: isSoftLogout, generation: generation) }
        }
        authDelegate = auth
        authDelegateHandle = try? client.setDelegate(delegate: auth)
        reportedAuthErrorGeneration = nil
        delegate?.seed(session)
        self.client = client
        self.storeID = storeID
    }

    private func handleAuthError(isSoftLogout: Bool, generation: UInt64) async {
        guard sessionGeneration == generation, client != nil else { return }
        guard reportedAuthErrorGeneration != generation else { return }
        reportedAuthErrorGeneration = generation
        let storeID = self.storeID
        await stopSync()
        if !isSoftLogout {
            clearClientState()
            if let storeID { Self.removeStore(baseDirectory, storeID) }
        }
        emit(isSoftLogout ? .softLoggedOut : .loggedOut)
    }

    private func clearClientState() {
        client = nil
        storeID = nil
        delegate = nil
        authDelegateHandle?.cancel()
        authDelegateHandle = nil
        authDelegate = nil
        sendQueueErrorsHandle?.cancel()
        sendQueueErrorsHandle = nil
        sendQueueErrors = nil
        searchBackfillHandle?.cancel()
        searchBackfillHandle = nil
    }

    fileprivate func emit(_ event: SessionEvent) {
        for continuation in events.values { continuation.yield(event) }
    }

    private func makeClient(
        homeserver: String, storeID: String, passphrase: String, initialSession: Session? = nil
    ) async throws -> Client {
        let data = baseDirectory.appendingPathComponent(storeID, isDirectory: true).appendingPathComponent("data")
        let cache = baseDirectory.appendingPathComponent(storeID, isDirectory: true).appendingPathComponent("caches")
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let persist = self.persistRefreshedSession
        let delegate = RefreshDelegate(
            storeID: storeID,
            passphrase: passphrase,
            initialSession: initialSession,
            readStoredSession: readStoredSession
        ) { [weak self] stored in
            persist?(stored)
            guard let self else { return }
            Task { await self.emit(.tokensRefreshed(stored)) }
        }
        self.delegate = delegate
        let slidingSyncBuilder: SlidingSyncVersionBuilder = enablesSlidingSync ? .native : .none
        var builder = ClientBuilder()
            .serverNameOrHomeserverUrl(serverNameOrUrl: homeserver)
            .sessionPaths(dataPath: data.path, cachePath: cache.path)
            .sqliteStore(config: SqliteStoreBuilder(dataPath: data.path, cachePath: cache.path).passphrase(passphrase: passphrase))
            .slidingSyncVersionBuilder(versionBuilder: slidingSyncBuilder)
            .autoEnableCrossSigning(autoEnableCrossSigning: true)
            .autoEnableBackups(autoEnableBackups: true)
            .crossProcessLockConfig(crossProcessLockConfig: .multiProcess(holderName: holderName))
            .setSessionDelegate(sessionDelegate: delegate)
        if sendsMessages {
            let searchIndex = baseDirectory.appendingPathComponent(storeID, isDirectory: true).appendingPathComponent("search-index")
            try FileManager.default.createDirectory(at: searchIndex, withIntermediateDirectories: true)
            builder = builder
                .withSearchIndexStore(path: searchIndex.path, key: passphrase)
                .enableAutomaticBackPagination(enableAutomaticBackPagination: true)
        }
        return try await builder.build()
    }

    static func sdkSession(from stored: StoredSession) throws(HaloError) -> Session {
        let payload: SessionPayload
        do { payload = try JSONDecoder().decode(SessionPayload.self, from: stored.payload) } catch {
            throw .storage(.corrupted)
        }
        return Session(
            accessToken: payload.accessToken, refreshToken: payload.refreshToken, userId: payload.userID,
            deviceId: payload.deviceID, homeserverUrl: payload.homeserverURL, oauthData: payload.oauthData,
            slidingSyncVersion: .none)
    }

    static func stored(from session: Session, storeID: String, passphrase: String) throws(HaloError) -> StoredSession {
        let payload = SessionPayload(
            accessToken: session.accessToken, refreshToken: session.refreshToken, userID: session.userId,
            deviceID: session.deviceId, homeserverURL: session.homeserverUrl, oauthData: session.oauthData,
            storeID: storeID, passphrase: passphrase)
        let data: Data
        do { data = try JSONEncoder().encode(payload) } catch { throw .internal(code: "SESSION_ENCODE") }
        return StoredSession(userID: try UserID(session.userId), deviceID: try DeviceID(session.deviceId), payload: data)
    }

    private static func randomPassphrase() -> String {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        return Data(bytes).base64EncodedString()
    }

    private static func removeStore(_ base: URL, _ storeID: String) {
        try? FileManager.default.removeItem(at: base.appendingPathComponent(storeID, isDirectory: true))
    }
}

/// Receives token refreshes from the SDK and turns them into `SessionEvent`s (AUTHENTICATION FR-7).
/// The SDK's own keychain callbacks are served from the last session it told us about.
/// Records that some room's send queue hit an error (the SDK then disables that room's queue). Only a flag: the callback must
/// not block or call back into the SDK (AGENTS.md §8); the error itself is shown per message through its local echo.
private final class SendQueueErrors: SendQueueRoomErrorListener {
    private let failed = Atomic(false)
    func onError(roomId: String, error: ClientError) { failed.store(true, ordering: .relaxed) }
    /// Whether an error was reported since the last call.
    func take() -> Bool { failed.exchange(false, ordering: .relaxed) }
}

private final class AuthDelegate: ClientDelegate, Sendable {
    private let onAuthError: @Sendable (Bool) -> Void

    init(onAuthError: @escaping @Sendable (Bool) -> Void) {
        self.onAuthError = onAuthError
    }

    func didReceiveAuthError(isSoftLogout: Bool) {
        // Never block the callback thread or call back into the FFI synchronously (AGENTS.md §8).
        onAuthError(isSoftLogout)
    }

    func onBackgroundTaskErrorReport(taskName: String, error: BackgroundTaskFailureReason) {}
}

final class RefreshDelegate: ClientSessionDelegate, Sendable {
    private let storeID: String
    private let passphrase: String
    private let readStoredSession: (@Sendable () -> StoredSession?)?
    private let onRefresh: @Sendable (StoredSession) -> Void
    private let latest: Mutex<Session?>

    init(
        storeID: String,
        passphrase: String,
        initialSession: Session? = nil,
        readStoredSession: (@Sendable () -> StoredSession?)? = nil,
        onRefresh: @escaping @Sendable (StoredSession) -> Void
    ) {
        self.storeID = storeID
        self.passphrase = passphrase
        self.readStoredSession = readStoredSession
        self.onRefresh = onRefresh
        self.latest = Mutex(initialSession)
    }

    func seed(_ session: Session) {
        latest.withLock { current in
            if current == nil { current = session }
        }
    }

    func retrieveSessionFromKeychain(userId: String) throws -> Session {
        // Prefer the shared Keychain when wired so cross-process token rotations (app ↔ NSE) are visible immediately (R-11).
        if let stored = readStoredSession?(),
           let session = try? MatrixSessionPort.sdkSession(from: stored),
           session.userId == userId {
            latest.withLock { $0 = session }
            return session
        }
        guard let session = latest.withLock({ $0 }), session.userId == userId else { throw HaloError.notFound }
        return session
    }

    func saveSessionInKeychain(session: Session) {
        latest.withLock { $0 = session }
        // A session we can't represent is dropped here; the next refresh reports again.
        if let stored = try? MatrixSessionPort.stored(from: session, storeID: storeID, passphrase: passphrase) {
            onRefresh(stored)
        }
    }
}
