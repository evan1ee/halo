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
    private var client: Client?
    private var syncService: SyncService?
    private var storeID: String?
    private var delegate: RefreshDelegate?
    private var events: [UUID: AsyncStream<SessionEvent>.Continuation] = [:]

    /// - Parameter baseDirectory: where per-login SDK stores live (the App Group container in the app).
    public init(baseDirectory: URL, holderName: String = "app") {
        self.baseDirectory = baseDirectory
        self.holderName = holderName
    }

    // MARK: SessionPort

    public func loginDetails(server: String) async throws(HaloError) -> ServerDetails {
        let trimmed = server.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw .invalidInput("SERVER_EMPTY") }
        try MatrixBootstrap.initialise()
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
            adopt(client, storeID: newStoreID, session: try client.session())
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
                slidingSyncVersion: .native)
            try await client.restoreSession(session: sdkSession)
            adopt(client, storeID: payload.storeID, session: sdkSession)
        } catch { throw ErrorMapper.map(error) }
    }

    public func logout() async throws(HaloError) {
        let client = self.client
        let storeID = self.storeID
        await syncService?.stop()
        syncService = nil
        self.client = nil
        self.storeID = nil
        delegate = nil
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

    // MARK: Shared with the room list

    /// The synchronising room list service; starts `SyncService` on first use.
    func roomListService() async throws(HaloError) -> RoomListService {
        guard let client else { throw .unauthorized(soft: false) }
        do {
            if syncService == nil { syncService = try await client.syncService().finish() }
            guard let syncService else { throw HaloError.internal(code: "SYNC_SERVICE") }
            await syncService.start()
            return syncService.roomListService()
        } catch { throw ErrorMapper.map(error) }
    }

    // MARK: Internals

    private func register(_ continuation: AsyncStream<SessionEvent>.Continuation, id: UUID) { events[id] = continuation }
    private func unregister(_ id: UUID) { events[id] = nil }

    private func adopt(_ client: Client, storeID: String, session: Session) {
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
            .slidingSyncVersionBuilder(versionBuilder: .native)
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
