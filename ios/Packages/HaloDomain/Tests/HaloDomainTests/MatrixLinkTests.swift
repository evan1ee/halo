import Foundation
import HaloDomain
import HaloFoundation
import Testing

@Suite("MatrixLink (NAVIGATION §3)")
struct MatrixLinkTests {
    @Test("parses matrix.to user, room, room+event, and alias links with percent-encoding and via params")
    func parsesMatrixToLinks() throws {
        let userURL = try #require(URL(string: "https://matrix.to/#/%40alice%3Aexample.org"))
        #expect(MatrixLink.parse(userURL) == .user(try UserID("@alice:example.org")))

        let roomURL = try #require(URL(string: "https://matrix.to/#/!room1:example.org?via=example.org"))
        #expect(MatrixLink.parse(roomURL) == .room(try RoomID("!room1:example.org"), event: nil))

        let eventURL = try #require(URL(string: "https://matrix.to/#/!room1:example.org/$ev42?via=example.org"))
        #expect(MatrixLink.parse(eventURL) == .room(try RoomID("!room1:example.org"), event: try EventID("$ev42")))

        let aliasURL = try #require(URL(string: "https://matrix.to/#/%23halo%3Aexample.org/%24ev9"))
        #expect(MatrixLink.parse(aliasURL) == .roomAlias("#halo:example.org", event: try EventID("$ev9")))
    }

    @Test("parses MSC2312 matrix: URIs")
    func parsesMatrixURIs() throws {
        let u = try #require(URL(string: "matrix:u/bob:example.org"))
        #expect(MatrixLink.parse(u) == .user(try UserID("@bob:example.org")))

        let r = try #require(URL(string: "matrix:r/halo:example.org/e/ev7?action=join"))
        #expect(MatrixLink.parse(r) == .roomAlias("#halo:example.org", event: try EventID("$ev7")))

        let roomID = try #require(URL(string: "matrix:roomid/abc:example.org/e/ev1"))
        #expect(MatrixLink.parse(roomID) == .room(try RoomID("!abc:example.org"), event: try EventID("$ev1")))
    }

    @Test("rejects unrelated hosts and malformed URLs")
    func rejectsInvalidLinks() throws {
        #expect(MatrixLink.parse(try #require(URL(string: "https://example.org/#/@alice:example.org"))) == nil)
        #expect(MatrixLink.parse(try #require(URL(string: "https://matrix.to/#/not-valid"))) == nil)
        #expect(MatrixLink.parse(try #require(URL(string: "matrix:unknown/foo"))) == nil)
    }
}
