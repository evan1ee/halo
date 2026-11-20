import Foundation
import HaloDomain
import HaloFoundation
import HaloTestSupport
import Testing
@testable import HaloApplication

@Suite("EncryptionCoordinator")
struct EncryptionCoordinatorTests {
    private func make(_ port: FakeEncryptionPort) async throws -> (EncryptionCoordinator, SessionCoordinator) {
        let sessionPort = FakeSessionPort()
        let url = try #require(URL(string: "https://example.org"))
        sessionPort.addServer("example.org", ServerDetails(homeserverURL: url, supportsPassword: true, supportsOIDC: false, supportsNativeSlidingSync: true))
        sessionPort.addAccount(.init(localpart: "alice", password: "pw"))
        let session = SessionCoordinator(port: sessionPort, keychain: InMemoryKeychain())
        await session.start()
        let coordinator = EncryptionCoordinator(port: port, session: session)
        await coordinator.begin()
        await session.discover(server: "example.org")
        await session.loginPassword(username: "alice", password: "pw")
        return (coordinator, session)
    }

    private func wait(_ coordinator: EncryptionCoordinator, _ predicate: @Sendable (EncryptionCoordinator.Snapshot) -> Bool) async -> EncryptionCoordinator.Snapshot? {
        for await snapshot in await coordinator.snapshots() where predicate(snapshot) { return snapshot }
        return nil
    }

    @Test("an unverified device with recovery set up is reported once signed in")
    func reportsStatus() async throws {
        let (coordinator, _) = try await make(FakeEncryptionPort(recoveryKey: "k"))
        let snapshot = await wait(coordinator) { $0.status.needsRecovery }
        #expect(snapshot?.status == EncryptionStatus(verification: .unverified, recovery: .incomplete))
    }

    @Test("a wrong key fails with the input error and stays unverified; the right key verifies")
    func recovers() async throws {
        let port = FakeEncryptionPort(recoveryKey: "right")
        let (coordinator, _) = try await make(port)
        _ = await wait(coordinator) { $0.status.needsRecovery }

        await coordinator.recover(recoveryKey: "wrong")
        #expect(await coordinator.snapshot.recovery == .failed(.invalidInput("RECOVERY_KEY")))
        #expect(port.status.verification == .unverified)

        await coordinator.recover(recoveryKey: "  right \n")  // pasted keys often carry whitespace
        #expect(await coordinator.snapshot.recovery == .idle)
        #expect(await wait(coordinator) { $0.status.verification == .verified } != nil)
    }

    @Test("an empty key is rejected without calling the port")
    func emptyKey() async throws {
        let port = FakeEncryptionPort(recoveryKey: "right")
        let (coordinator, _) = try await make(port)
        await coordinator.recover(recoveryKey: "   ")
        #expect(await coordinator.snapshot.recovery == .failed(.invalidInput("RECOVERY_KEY")))
        #expect(port.status.verification == .unverified)
    }

    @Test("signing out forgets the status")
    func signOut() async throws {
        let (coordinator, session) = try await make(FakeEncryptionPort(recoveryKey: "k"))
        _ = await wait(coordinator) { $0.status.needsRecovery }
        await session.logout()
        #expect(await wait(coordinator) { $0.status == .unknown } != nil)
    }

    @Test("setting up recovery returns the new key once, leaves the coordinator idle and reports recovery on")
    func setsUpRecovery() async throws {
        let port = FakeEncryptionPort(recoveryKey: nil)
        let (coordinator, _) = try await make(port)
        _ = await wait(coordinator) { $0.status.recovery == .disabled }
        let key = try await coordinator.enableRecovery()
        #expect(key.hasPrefix("FAKE-RECOVERY-KEY"))
        #expect(await coordinator.snapshot.recovery == .idle)
        #expect(await wait(coordinator) { $0.status.recovery == .enabled } != nil)
    }
}
