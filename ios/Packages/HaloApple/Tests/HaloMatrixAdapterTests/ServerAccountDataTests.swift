import Foundation
import HaloDomain
import HaloFoundation
import Synchronization
import Testing
@testable import HaloMatrixAdapter

@Suite("Account data is changed from the server's copy (D120)")
struct ServerAccountDataTests {
    private final class Server: Sendable {
        let data = Mutex<[String: String]>([:])
        let writes = Mutex(0)
        let failing = Mutex(false)

        var accountData: ServerAccountData {
            ServerAccountData(
                read: { type in
                    if self.failing.withLock({ $0 }) { throw URLError(.notConnectedToInternet) }
                    return self.data.withLock { $0[type] }.map { Data($0.utf8) }
                },
                write: { type, content in
                    self.writes.withLock { $0 += 1 }
                    self.data.withLock { $0[type] = content }
                })
        }
    }

    private let type = "m.image_pack.rooms"

    @Test("enabling a pack keeps the listed ones and unknown keys; two changes in a row both stay")
    func keepsWhatIsThere() async throws {
        let server = Server()
        server.data.withLock { $0[type] = #"{"other":1,"rooms":{"!old:x.org":{"cats":{"k":"v"}}}}"# }
        let first = PackRef(room: try RoomID("!a:x.org"), stateKey: "pack"), second = PackRef(room: try RoomID("!b:x.org"), stateKey: "pack")
        try await server.accountData.update(type) { PackRegistry.enabling(first, in: $0) }
        try await server.accountData.update(type) { PackRegistry.enabling(second, in: $0) }
        #expect(server.data.withLock { $0[type] } == #"{"other":1,"rooms":{"!a:x.org":{"pack":{}},"!b:x.org":{"pack":{}},"!old:x.org":{"cats":{"k":"v"}}}}"#)
    }

    @Test("without any (404) it is created; nothing to change writes nothing")
    func createsAndLeavesAlone() async throws {
        let server = Server()
        let ref = PackRef(room: try RoomID("!a:x.org"), stateKey: "pack")
        try await server.accountData.update(type) { PackRegistry.disabling(ref, in: $0) }
        #expect(server.writes.withLock { $0 } == 0)
        try await server.accountData.update(type) { PackRegistry.enabling(ref, in: $0) }
        #expect(server.data.withLock { $0[type] } == #"{"rooms":{"!a:x.org":{"pack":{}}}}"#)
    }

    @Test("a copy that can't be read or isn't an object is never overwritten")
    func unreadable() async throws {
        let server = Server()
        let ref = PackRef(room: try RoomID("!a:x.org"), stateKey: "pack")
        server.data.withLock { $0[type] = "[1]" }
        await #expect(throws: HaloError.internal(code: "ACCOUNT_DATA_MALFORMED")) {
            try await server.accountData.update(type) { PackRegistry.enabling(ref, in: $0) }
        }
        server.failing.withLock { $0 = true }
        await #expect(throws: URLError.self) { try await server.accountData.update(type) { PackRegistry.enabling(ref, in: $0) } }
        #expect(server.writes.withLock { $0 } == 0)
    }
}
