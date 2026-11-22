import Foundation
import HaloDomain
import HaloFoundation
import Testing
@testable import HaloTestSupport

/// The fakes must satisfy the same contracts as the real adapter.
@Suite("Fakes satisfy the port contracts")
struct FakeContractTests {
    static let details = ServerDetails(
        homeserverURL: URL(string: "https://halo.localhost")!,
        supportsPassword: true, supportsOIDC: false, supportsNativeSlidingSync: true
    )

    @Test("FakeSessionPort")
    func session() async throws {
        let port = FakeSessionPort()
        let account = FakeSessionPort.Account(localpart: "alice", password: "correct horse")
        port.addServer("halo.localhost", Self.details)
        port.addAccount(account)
        try await SessionPortContract.verify(port, server: "halo.localhost", account: account)
    }

    @Test("FakeRoomListPort")
    func roomList() async throws {
        let rooms = try (1...3).map { RoomSummary(id: try RoomID("!r\($0)"), name: nil, isDirect: false, isEncrypted: false, membership: .joined) }
        let port = FakeRoomListPort(rooms: rooms)
        try await RoomListPortContract.verify(port, expectedRoomCount: 3)
    }

    @Test("a contract violation is reported")
    func violation() async throws {
        let port = FakeSessionPort()
        port.addServer("halo.localhost", Self.details)
        // No account: the correct-password login fails, which the contract must catch.
        await #expect(throws: (any Error).self) {
            try await SessionPortContract.verify(port, server: "halo.localhost", account: .init(localpart: "bob", password: "pw"))
        }
    }
}
