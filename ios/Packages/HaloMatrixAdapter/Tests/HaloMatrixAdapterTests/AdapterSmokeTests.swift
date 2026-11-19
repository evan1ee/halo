import HaloDomain
import HaloFoundation
import MatrixRustSDK
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

@Suite("MatrixRoomListPort mapping")
struct RoomListMappingTests {
    @Test("filters map to SDK kinds; unread is explicitly unsupported until M1")
    func filters() throws {
        #expect(try MatrixRoomListPort.kind(for: .invites) == .invite)
        #expect(throws: HaloError.unsupported("FILTER_UNREAD_M1")) { try MatrixRoomListPort.kind(for: .unread) }
    }

    @Test("memberships map one to one")
    func membership() {
        #expect(MatrixRoomListPort.membership(.joined) == .joined)
        #expect(MatrixRoomListPort.membership(.banned) == .banned)
    }
}
