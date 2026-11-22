import Foundation
import Testing
@testable import HaloFoundation

@Suite("Matrix identifiers")
struct IdentifierTests {
    @Test("valid identifiers are accepted", arguments: ["@alice:halo.localhost", "@a:b", "@alice:[::1]:8448"])
    func validUserIDs(raw: String) throws {
        #expect(try UserID(raw).rawValue == raw)
    }

    @Test("invalid user IDs are rejected with a reason code", arguments: [
        ("alice:halo.localhost", "USER_ID_SIGIL"),
        ("@", "USER_ID_BODY"),
        ("@alice", "USER_ID_SERVER_NAME"),
        ("@:halo.localhost", "USER_ID_SERVER_NAME"),
        ("@alice:", "USER_ID_SERVER_NAME"),
        ("@al ice:halo.localhost", "USER_ID_BODY"),
    ])
    func invalidUserIDs(raw: String, reason: String) {
        #expect(throws: HaloError.invalidInput(reason)) { try UserID(raw) }
    }

    @Test("room IDs don't require a server name")
    func roomIDs() throws {
        #expect(try RoomID("!abc:halo.localhost").rawValue == "!abc:halo.localhost")
        #expect(try RoomID("!opaqueOnly").rawValue == "!opaqueOnly")
        #expect(throws: HaloError.invalidInput("ROOM_ID_SIGIL")) { try RoomID("#alias:halo.localhost") }
    }

    @Test("event and device IDs")
    func eventAndDeviceIDs() throws {
        #expect(try EventID("$abc").rawValue == "$abc")
        #expect(throws: HaloError.invalidInput("EVENT_ID_SIGIL")) { try EventID("abc") }
        #expect(throws: HaloError.invalidInput("DEVICE_ID_LENGTH")) { try DeviceID("") }
    }

    @Test("identifiers longer than 255 bytes are rejected")
    func length() {
        let raw = "@" + String(repeating: "a", count: 250) + ":host"
        #expect(throws: HaloError.invalidInput("USER_ID_LENGTH")) { try UserID(raw) }
    }

    @Test("string interpolation never contains the raw identifier")
    func redaction() throws {
        let user = try UserID("@alice:halo.localhost")
        let room = try RoomID("!secret:halo.localhost")
        #expect("\(user) \(room)" == "UserID(<redacted>) RoomID(<redacted>)")
        #expect(String(reflecting: user) == "UserID(<redacted>)")
    }

    @Test("Codable round-trips the raw value and rejects invalid input")
    func codable() throws {
        let user = try UserID("@alice:halo.localhost")
        let data = try JSONEncoder().encode([user])
        #expect(String(decoding: data, as: UTF8.self) == #"["@alice:halo.localhost"]"#)
        #expect(try JSONDecoder().decode([UserID].self, from: data) == [user])
        #expect(throws: DecodingError.self) { try JSONDecoder().decode([UserID].self, from: Data(#"["alice"]"#.utf8)) }
    }
}

@Suite("HaloError")
struct HaloErrorTests {
    @Test("codes are stable")
    func codes() {
        #expect(HaloError.network(retryable: true).code == "NET_RETRYABLE")
        #expect(HaloError.unauthorized(soft: true).code == "AUTH_SOFT_LOGOUT")
        #expect(HaloError.unsupported("NO_SLIDING_SYNC").code == "UNSUPPORTED_NO_SLIDING_SYNC")
        #expect(HaloError.storage(.unavailable).code == "STORAGE_UNAVAILABLE")
    }

    @Test("only retryable network errors are retryable")
    func retryable() {
        #expect(HaloError.network(retryable: true).isRetryable)
        #expect(!HaloError.network(retryable: false).isRetryable)
        #expect(!HaloError.unauthorized(soft: true).isRetryable)
    }
}

@Suite("SeededRandomNumberGenerator")
struct SeededRandomTests {
    @Test("the same seed gives the same sequence")
    func deterministic() {
        var a = SeededRandomNumberGenerator(seed: 42), b = SeededRandomNumberGenerator(seed: 42)
        var c = SeededRandomNumberGenerator(seed: 43)
        let first = (0..<100).map { _ in a.next() }
        #expect(first == (0..<100).map { _ in b.next() })
        #expect(first != (0..<100).map { _ in c.next() })
        #expect(a.seed == 42)
    }
}
