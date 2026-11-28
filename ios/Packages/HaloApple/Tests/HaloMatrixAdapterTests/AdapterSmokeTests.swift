import Foundation
import HaloDomain
import HaloFoundation
import MatrixRustSDK
import Synchronization
import Testing
@testable import HaloMatrixAdapter

@Suite("ErrorMapper")
struct ErrorMapperTests {
    @Test("a hard-revoked token is a hard unauthorized, a soft logout keeps the session")
    func tokens() {
        #expect(ErrorMapper.map(.unknownToken(softLogout: false)) == .unauthorized(soft: false))
        #expect(ErrorMapper.map(.unknownToken(softLogout: true)) == .unauthorized(soft: true))
        #expect(ErrorMapper.map(.missingToken) == .unauthorized(soft: false))
    }

    @Test("rate limiting is retryable, forbidden and not-found keep their meaning")
    func others() {
        #expect(ErrorMapper.map(.limitExceeded(retryAfterMs: nil)) == .network(retryable: true))
        #expect(ErrorMapper.map(.forbidden) == .forbidden)
        #expect(ErrorMapper.map(.notFound) == .notFound)
    }

    @Test("a rejected login (M_FORBIDDEN) is wrong credentials, not a permissions error")
    func loginForbidden() {
        let forbidden = ClientError.MatrixApi(kind: .forbidden, code: "M_FORBIDDEN", msg: "", details: nil)
        #expect(ErrorMapper.mapLogin(forbidden) == .unauthorized(soft: false))
        #expect(ErrorMapper.map(forbidden) == .forbidden)
    }

    @Test("build errors map to discovery outcomes")
    func build() {
        #expect(ErrorMapper.map(ClientBuildError.ServerUnreachable(message: "x")) == .network(retryable: true))
        #expect(ErrorMapper.map(ClientBuildError.InvalidServerName(message: "x")) == .invalidInput("SERVER_NAME"))
        #expect(ErrorMapper.map(ClientBuildError.SlidingSyncVersion(message: "x")) == .unsupported("NO_SLIDING_SYNC"))
    }

    @Test("SDK message text never reaches a HaloError")
    func noServerText() {
        let mapped = ErrorMapper.map(ClientError.Generic(msg: "secret@room", details: nil))
        #expect(!mapped.code.contains("secret"))
    }

    @Test("R-27: mapLocalEcho maps EventNotInTimeline to .notFound and preserves other errors")
    func localEchoErrors() {
        let missing = ClientError.Generic(msg: "Event not found in timeline: TransactionId(\"t1\")", details: nil)
        #expect(ErrorMapper.mapLocalEcho(missing) == .notFound)
        let other = ClientError.Generic(msg: "database locked", details: nil)
        #expect(ErrorMapper.mapLocalEcho(other) == .internal(code: "SDK_GENERIC"))
        let unauth = ClientError.MatrixApi(kind: .unknownToken(softLogout: false), code: "M_UNKNOWN_TOKEN", msg: "", details: nil)
        #expect(ErrorMapper.mapLocalEcho(unauth) == .unauthorized(soft: false))
    }
}

@Suite("TimelineMapper UTD reasons")
struct UTDReasonTests {
    @Test("the SDK's cause maps to Halo's reason; non-megolm or unknown causes are .unknown")
    func reasons() {
        func reason(_ cause: UtdCause) -> UTDReason { TimelineMapper.reason(of: .megolmV1AesSha2(sessionId: "s", cause: cause)) }
        #expect(reason(.sentBeforeWeJoined) == .sentBeforeJoining)
        #expect(reason(.unsignedDevice) == .keysNotShared)
        #expect(reason(.unknownDevice) == .keysNotShared)
        #expect(reason(.verificationViolation) == .senderVerificationProblem)
        #expect(reason(.historicalMessageAndBackupIsDisabled) == .backupDisabled)
        #expect(reason(.unknown) == .unknown)
        #expect(TimelineMapper.reason(of: .unknown) == .unknown)
    }
}

@Suite("MatrixRoomListPort mapping")
struct RoomListMappingTests {
    @Test("unread is explicitly unsupported until M1; every other filter is accepted")
    func filters() throws {
        for filter in [RoomListFilter.all, .people, .rooms, .favourites, .invites] { try MatrixRoomListPort.kind(for: filter) }
        #expect(throws: HaloError.unsupported("FILTER_UNREAD_M1")) { try MatrixRoomListPort.kind(for: .unread) }
    }

    @Test("rooms are ordered invites first, then newest latest event first, rooms without events last, ties by id")
    func ordering() throws {
        func room(_ id: String, _ time: Int?, invited: Bool = false) throws -> RoomSummary {
            RoomSummary(
                id: try RoomID(id), name: id, isDirect: false, isEncrypted: false, membership: invited ? .invited : .joined,
                latestEvent: time.map { LatestEventRef(timestamp: Date(timeIntervalSince1970: Double($0)), senderIsSelf: false) })
        }
        let shuffled = [try room("!e:x", nil), try room("!old:x", 10), try room("!new:x", 20), try room("!inv:x", nil, invited: true), try room("!d:x", nil)]
        #expect(shuffled.sorted(by: MatrixRoomListPort.order).map(\.id.rawValue) == ["!inv:x", "!new:x", "!old:x", "!d:x", "!e:x"])
    }

    @Test("memberships map one to one")
    func membership() {
        #expect(MatrixRoomListPort.membership(.joined) == .joined)
        #expect(MatrixRoomListPort.membership(.banned) == .banned)
    }

    @Test("EventTimeCache persists derived timestamps across instances, ignores corrupt files, and deletes on clear (GA-28, M19-7)")
    func eventTimeCachePersistence() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("halo-etc-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("times.json")

        let first = MatrixRoomListPort.EventTimeCache(file: file)
        let ts = Date(timeIntervalSince1970: 1_700_000_123.456)
        first.set("$ev1", ts)
        first.flushNow()
        #expect(FileManager.default.fileExists(atPath: file.path))

        let restored = MatrixRoomListPort.EventTimeCache(file: file)
        let loaded = try #require(restored.get("$ev1"))
        #expect(abs(loaded.timeIntervalSince1970 - ts.timeIntervalSince1970) < 0.002)

        restored.clear()
        #expect(restored.get("$ev1") == nil)
        #expect(!FileManager.default.fileExists(atPath: file.path))

        try Data("not json".utf8).write(to: file)
        let corrupt = MatrixRoomListPort.EventTimeCache(file: file)
        #expect(corrupt.get("$ev1") == nil)

        // Bounded eviction retains the newest half of timestamps rather than wiping the whole cache.
        let bounded = MatrixRoomListPort.EventTimeCache(limit: 4)
        for step in 1...5 {
            bounded.set("$e\(step)", Date(timeIntervalSince1970: Double(step * 100)))
        }
        #expect(bounded.get("$e5") != nil && bounded.get("$e4") != nil && bounded.get("$e3") != nil)
        #expect(bounded.get("$e1") == nil && bounded.get("$e2") == nil)
    }

    @Test("GalleryCollector.settle awaits asynchronous listener delivery before returning media items (M19-5)")
    func galleryCollectorSettlesAsyncDiffs() async throws {
        let collector = GalleryCollector(ownUserID: "@me:x.org", sleep: { _ in await Task.yield() })
        let mediaEvent = HaloDomain.TimelineItem(
            id: TimelineItemID("g1"),
            content: .event(HaloDomain.TimelineEvent(
                eventID: try EventID("$img1:x.org"),
                sender: try UserID("@alice:x.org"),
                senderName: "Alice",
                timestamp: Date(timeIntervalSince1970: 1_000),
                isOwn: false,
                kind: .media(MediaAttachment(kind: .image, body: "sunset.jpg", source: MediaRef(token: "m1"))))))

        let delivery = Task {
            for _ in 0..<5 { await Task.yield() }
            collector.applyMapped([.reset([mediaEvent])])
        }
        await collector.settle(after: 0)
        await delivery.value
        let items = try collector.mediaItemsNewestFirst()
        #expect(items.map(\.attachment.body) == ["sunset.jpg"])
    }
}

@Suite("MatrixBootstrap (R-09 / §7)")
struct MatrixBootstrapTests {
    @Test("tracing disables Sentry and stdout/system logging (§7, SECURITY §6)")
    func tracingConfig() {
        let config = MatrixBootstrap.tracingConfiguration()
        #expect(config.sentryConfig == nil)
        #expect(config.writeToStdoutOrSystem == false)
        #expect(config.writeToFiles == nil)
    }

    @Test("R-09: MatrixSessionPort forwards lightweightRuntime through restore and loginPassword")
    func lightweightRuntimeForwarded() async throws {
        let recorded = Mutex<[Bool]>([])
        let port = MatrixSessionPort(
            baseDirectory: FileManager.default.temporaryDirectory,
            holderName: "nse",
            sendsMessages: false,
            lightweightRuntime: true,
            initialisePlatform: { lightweight throws(HaloError) in
                recorded.withLock { $0.append(lightweight) }
                throw .cancelled  // stop before touching the network/filesystem
            })
        let dummy = StoredSession(userID: try UserID("@a:x"), deviceID: try DeviceID("DEV"), payload: Data())
        do { try await port.restore(dummy) } catch {}
        let server = ServerDetails(homeserverURL: URL(string: "https://example.invalid")!, supportsPassword: true, supportsOIDC: false, supportsNativeSlidingSync: true)
        do { _ = try await port.loginPassword(PasswordCredentials(username: "a", password: "b", deviceDisplayName: "d"), on: server) } catch {}
        #expect(recorded.withLock { $0 } == [true, true])
    }
}

@Suite("RefreshDelegate (R-11)")
struct RefreshDelegateTests {
    @Test("retrieveSessionFromKeychain returns the initial restored session before any save and reads shared Keychain updates")
    func retrieveAndPersist() throws {
        let initial = Session(
            accessToken: "tok-1", refreshToken: "ref-1", userId: "@alice:x",
            deviceId: "DEV1", homeserverUrl: "https://x", oauthData: nil, slidingSyncVersion: .none)
        let persisted = Mutex<StoredSession?>(nil)
        let delegate = RefreshDelegate(
            storeID: "store-1",
            passphrase: "pass",
            initialSession: initial,
            readStoredSession: { persisted.withLock { $0 } },
            onRefresh: { stored in persisted.withLock { $0 = stored } })

        // Before the first save in this process, retrieveSessionFromKeychain returns the restored session.
        let beforeSave = try delegate.retrieveSessionFromKeychain(userId: "@alice:x")
        #expect(beforeSave.accessToken == "tok-1")
        #expect(beforeSave.refreshToken == "ref-1")

        // Mismatched user ID is rejected.
        #expect(throws: HaloError.notFound) { _ = try delegate.retrieveSessionFromKeychain(userId: "@bob:x") }

        // A token refresh persists synchronously via onRefresh (NSE path) and is visible to subsequent retrieves.
        let rotated = Session(
            accessToken: "tok-2", refreshToken: "ref-2", userId: "@alice:x",
            deviceId: "DEV1", homeserverUrl: "https://x", oauthData: nil, slidingSyncVersion: .none)
        delegate.saveSessionInKeychain(session: rotated)
        let stored = try #require(persisted.withLock { $0 })
        #expect(stored.userID == (try UserID("@alice:x")))

        // A second delegate (simulating the other process) reads the rotated tokens from the shared Keychain.
        let otherProcess = RefreshDelegate(
            storeID: "store-1",
            passphrase: "pass",
            initialSession: initial,
            readStoredSession: { persisted.withLock { $0 } },
            onRefresh: { _ in })
        let crossProcess = try otherProcess.retrieveSessionFromKeychain(userId: "@alice:x")
        #expect(crossProcess.accessToken == "tok-2")
        #expect(crossProcess.refreshToken == "ref-2")
    }

    @Test("defaultMediaRetentionPolicy matches D55 / V-MEDIA-1 (1 GiB, 50 MiB max file, 30 days, daily cleanup)")
    func mediaRetentionPolicyDefaults() {
        let policy = MatrixSessionPort.defaultMediaRetentionPolicy
        #expect(policy.maxCacheSize == 1_073_741_824)
        #expect(policy.maxFileSize == 52_428_800)
        #expect(policy.lastAccessExpiry == TimeInterval(30 * 86_400))
        #expect(policy.cleanupFrequency == TimeInterval(86_400))
    }
}
