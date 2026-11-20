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
    private var client: Client?
    private var syncTask: Task<Void, Never>?
    private var stoppingTask: Task<Void, Never>?
    private var statusObservers: [UUID: @Sendable (SyncStatus) -> Void] = [:]
    private var changeObservers: [UUID: AsyncStream<SyncChange>.Continuation] = [:]
    private var storeID: String?
    private var delegate: RefreshDelegate?
    /// Set when a room's send queue reported an error (which disables that queue); the next successful sync re-enables them.
    private var sendQueueErrors: SendQueueErrors?
    private var sendQueueErrorsHandle: TaskHandle?
    private var events: [UUID: AsyncStream<SessionEvent>.Continuation] = [:]

    /// - Parameter baseDirectory: where per-login SDK stores live (the App Group container in the app).
    /// - Parameters:
    ///   - holderName: this process's name for the SDK's cross-process lock ("app" or "nse").
    ///   - sendsMessages: whether this process owns the unsent-message queues (the app does; the extension must not).
    ///   - lightweightRuntime: use the SDK's lightweight runtime (the extension does).
    public init(baseDirectory: URL, holderName: String = "app", sendsMessages: Bool = true, lightweightRuntime: Bool = false) {
        self.baseDirectory = baseDirectory
        self.holderName = holderName
        self.sendsMessages = sendsMessages
        self.lightweightRuntime = lightweightRuntime
    }

    // MARK: SessionPort

    public func loginDetails(server: String) async throws(HaloError) -> ServerDetails {
        let trimmed = server.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw .invalidInput("SERVER_EMPTY") }
        try MatrixBootstrap.initialise(lightweightRuntime: lightweightRuntime)
        do {
            let probe = try await ClientBuilder()
                .serverNameOrHomeserverUrl(serverNameOrUrl: trimmed)
                .slidingSyncVersionBuilder(versionBuilder: .discoverNative)
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
        guard server.supportsNativeSlidingSync else { throw .unsupported("NO_SLIDING_SYNC") }
        try MatrixBootstrap.initialise()
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
            await adopt(client, storeID: newStoreID, session: try client.session())
            return stored
        } catch let error as HaloError {
            throw error
        } catch {
            Self.removeStore(baseDirectory, newStoreID)
            throw ErrorMapper.map(error)
        }
    }

    public func restore(_ session: StoredSession) async throws(HaloError) {
        try MatrixBootstrap.initialise()
        let payload: SessionPayload
        do { payload = try JSONDecoder().decode(SessionPayload.self, from: session.payload) } catch {
            throw .storage(.corrupted)
        }
        do {
            let client = try await makeClient(
                homeserver: payload.homeserverURL, storeID: payload.storeID, passphrase: payload.passphrase)
            let sdkSession = Session(
                accessToken: payload.accessToken, refreshToken: payload.refreshToken, userId: payload.userID,
                deviceId: payload.deviceID, homeserverUrl: payload.homeserverURL, oauthData: payload.oauthData,
                slidingSyncVersion: .none)
            try await client.restoreSession(session: sdkSession)
            await adopt(client, storeID: payload.storeID, session: sdkSession)
        } catch { throw ErrorMapper.map(error) }
    }

    public func logout() async throws(HaloError) {
        let client = self.client
        let storeID = self.storeID
        await stopSync()
        self.client = nil
        self.storeID = nil
        delegate = nil
        sendQueueErrorsHandle?.cancel()
        sendQueueErrorsHandle = nil
        sendQueueErrors = nil
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
    /// plus the SDK's own, per room. Own loop, not `Client.syncV2`, so errors and backoff are visible: a retryable error
    /// reports `.offline` and retries; any other ends the loop with `.failed` (`SyncCoordinator` restarts it).
    func startSync() async throws(HaloError) {
        guard let client else { throw .unauthorized(soft: false) }
        guard syncTask == nil else { return }
        // A loop that was stopped may still be inside its long poll; two loops must never overlap.
        let previous = stoppingTask
        syncTask = Task { [weak self] in
            await previous?.value
            guard !Task.isCancelled else { return }
            await self?.runSync(client)
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

    private func runSync(_ client: Client) async {
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
                guard mapped.isRetryable else {
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

    // MARK: Internals

    private func register(_ continuation: AsyncStream<SessionEvent>.Continuation, id: UUID) { events[id] = continuation }
    private func unregister(_ id: UUID) { events[id] = nil }

    private func adopt(_ client: Client, storeID: String, session: Session) async {
        // Unsent messages survive an app kill and go out when the network returns (MESSAGING FR-3).
        if sendsMessages {
            await client.enableAllSendQueues(enable: true)
            let errors = SendQueueErrors()
            sendQueueErrorsHandle?.cancel()
            sendQueueErrorsHandle = client.subscribeToSendQueueStatus(listener: errors)
            sendQueueErrors = errors
        }
        self.client = client
        self.storeID = storeID
    }

    fileprivate func emit(_ event: SessionEvent) {
        for continuation in events.values { continuation.yield(event) }
    }

    private func makeClient(homeserver: String, storeID: String, passphrase: String) async throws -> Client {
        let data = baseDirectory.appendingPathComponent(storeID, isDirectory: true).appendingPathComponent("data")
        let cache = baseDirectory.appendingPathComponent(storeID, isDirectory: true).appendingPathComponent("caches")
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let delegate = RefreshDelegate(storeID: storeID, passphrase: passphrase) { [weak self] stored in
            guard let self else { return }
            Task { await self.emit(.tokensRefreshed(stored)) }
        }
        self.delegate = delegate
        return try await ClientBuilder()
            .serverNameOrHomeserverUrl(serverNameOrUrl: homeserver)
            .sessionPaths(dataPath: data.path, cachePath: cache.path)
            .sqliteStore(config: SqliteStoreBuilder(dataPath: data.path, cachePath: cache.path).passphrase(passphrase: passphrase))
            .slidingSyncVersionBuilder(versionBuilder: .none)
            .autoEnableCrossSigning(autoEnableCrossSigning: true)
            .autoEnableBackups(autoEnableBackups: true)
            .crossProcessLockConfig(crossProcessLockConfig: .multiProcess(holderName: holderName))
            .setSessionDelegate(sessionDelegate: delegate)
            .build()
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

private final class RefreshDelegate: ClientSessionDelegate, Sendable {
    private let storeID: String
    private let passphrase: String
    private let onRefresh: @Sendable (StoredSession) -> Void
    private let latest = Mutex<Session?>(nil)

    init(storeID: String, passphrase: String, onRefresh: @escaping @Sendable (StoredSession) -> Void) {
        self.storeID = storeID
        self.passphrase = passphrase
        self.onRefresh = onRefresh
    }

    func retrieveSessionFromKeychain(userId: String) throws -> Session {
        guard let session = latest.withLock({ $0 }) else { throw HaloError.notFound }
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
