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
