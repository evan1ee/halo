import Foundation
import HaloDomain
import HaloFoundation
import HaloTestSupport
import Testing
@testable import HaloMatrixAdapter

/// Runs the shared port contracts against a real homeserver (docs/testing/INTEGRATION_TESTS.md §3).
/// Enabled only when `HALO_DEV_SERVER`, `HALO_DEV_USER` and `HALO_DEV_PASSWORD` are set (an account on
/// `infra/dev`, see infra/dev/README.md); otherwise the tests are reported as skipped, never as passed.
private let env = ProcessInfo.processInfo.environment
private let configured = env["HALO_DEV_SERVER"] != nil && env["HALO_DEV_USER"] != nil && env["HALO_DEV_PASSWORD"] != nil

/// Real I/O needs a deadline: a contract that waits for a stream must fail, not hang.
private func within<T: Sendable>(seconds: Double, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            throw ContractViolation("timed out after \(seconds) s")
        }
        defer { group.cancelAll() }
        return try await group.next() ?? { throw ContractViolation("no result") }()
    }
}

@Suite("Adapter contracts against infra/dev", .serialized, .enabled(if: configured, "needs HALO_DEV_SERVER/USER/PASSWORD"))
struct AdapterContractTests {
    private func port() -> MatrixSessionPort {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("halo-contract-\(UUID().uuidString)")
        return MatrixSessionPort(baseDirectory: dir)
    }

    @Test("SessionPortContract")
    func session() async throws {
        let account = FakeSessionPort.Account(localpart: env["HALO_DEV_USER"] ?? "", password: env["HALO_DEV_PASSWORD"] ?? "")
        try await SessionPortContract.verify(port(), server: env["HALO_DEV_SERVER"] ?? "", account: account)
    }

    @Test("RoomListPortContract (the account must be in HALO_DEV_ROOMS rooms)")
    func roomList() async throws {
        let session = port()
        let server = env["HALO_DEV_SERVER"] ?? ""
        let details = try await session.loginDetails(server: server)
        let stored = try await session.loginPassword(
            PasswordCredentials(
                username: env["HALO_DEV_USER"] ?? "", password: env["HALO_DEV_PASSWORD"] ?? "",
                deviceDisplayName: "contract"),
            on: details)
        _ = stored
        let expected = Int(env["HALO_DEV_ROOMS"] ?? "0") ?? 0
        try await MatrixSyncPort(session: session).start()
        try await within(seconds: 60) { try await RoomListPortContract.verify(MatrixRoomListPort(session: session), expectedRoomCount: expected) }
        try await session.logout()
    }

    @Test("TimelinePortContract (HALO_DEV_TIMELINE_ROOM holds first, second, a notice, waves and a redacted message)", .enabled(if: env["HALO_DEV_TIMELINE_ROOM"] != nil))
    func timeline() async throws {
        let session = port()
        let details = try await session.loginDetails(server: env["HALO_DEV_SERVER"] ?? "")
        _ = try await session.loginPassword(
            PasswordCredentials(
                username: env["HALO_DEV_USER"] ?? "", password: env["HALO_DEV_PASSWORD"] ?? "", deviceDisplayName: "contract"),
            on: details)
        // The client only knows a room once sync has delivered it.
        let rooms = Int(env["HALO_DEV_ROOMS"] ?? "0") ?? 0
        try await MatrixSyncPort(session: session).start()
        try await within(seconds: 60) { try await RoomListPortContract.verify(MatrixRoomListPort(session: session), expectedRoomCount: rooms) }
        let timeline = MatrixTimelinePort(session: session)
        let room = try RoomID(env["HALO_DEV_TIMELINE_ROOM"] ?? "")
        try await within(seconds: 60) { try await TimelinePortContract.verify(timeline, room: room, expectedBodies: ["first", "second", "a notice", "waves"]) }
        try await TimelinePortContract.verifyUnknownRoom(timeline, room: try RoomID("!does-not-exist:localhost"))
        try await session.logout()
    }

    @Test("SyncPortContract")
    func sync() async throws {
        let session = port()
        let details = try await session.loginDetails(server: env["HALO_DEV_SERVER"] ?? "")
        _ = try await session.loginPassword(
            PasswordCredentials(
                username: env["HALO_DEV_USER"] ?? "", password: env["HALO_DEV_PASSWORD"] ?? "", deviceDisplayName: "contract"),
            on: details)
        let sync = MatrixSyncPort(session: session)
        try await within(seconds: 60) { try await SyncPortContract.verify(sync) }
        try await session.logout()
    }
}
